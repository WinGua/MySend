import 'dart:io';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../models/device_info.dart';
import '../../models/sync_mapping.dart';
import '../../storage/config_repository.dart';
import '../local_index_service.dart';
import 'part_store.dart';
import 'protocol.dart';

/// Android 端 HTTP 服务（协议 v2）。
///
/// - GET  /v2/hello
/// - POST /v2/pair
/// - GET  /v2/index     查询目标目录索引（供 PC 发起对比）
/// - GET  /v2/resume    查询已接收偏移
/// - POST /v2/upload    分片续传上传（原子落盘）
/// - POST /v2/log       接收对端同步日志
/// - POST /v2/disconnect
class ReceiverServer implements TransferServer {
  final int preferredPort;
  final String deviceId;
  final String deviceName;
  final String session;
  final ConfigRepository config;

  final void Function(PeerDevice peer, String peerToken) onPeerPaired;
  final Future<void> Function(String name, int count, int bytes, List<String> files)
      onSyncLog;
  final void Function(String deviceId) onDisconnect;

  /// 当前是否有同步任务占用（同一设备同一时刻只允许一个任务）。
  @override
  bool busy = false;

  /// 是否有上传正在写入分片，用于拒绝并发上传。
  bool _uploading = false;

  HttpServer? _server;
  final TokenStore _tokens = TokenStore();

  ReceiverServer({
    required this.preferredPort,
    required this.deviceId,
    required this.deviceName,
    required this.session,
    required this.config,
    required this.onPeerPaired,
    required this.onSyncLog,
    required this.onDisconnect,
  });

  @override
  int get port => _server?.port ?? preferredPort;

  @override
  bool get running => _server != null;

  @override
  String issueTokenFor(String deviceId) => _tokens.issueFor(deviceId);

  @override
  void revokeFor(String deviceId) => _tokens.revokeFor(deviceId);

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } catch (_) {
      // 端口被占用时退回系统分配端口，对端通过 hello 获取实际端口。
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _tokens.clear();
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/v2/hello') {
        _hello(req);
        return;
      }
      if (path == '/v2/pair') {
        await _pair(req);
        return;
      }

      final token = req.headers.value('X-MySend-Token');
      if (token == null || !_tokens.contains(token)) {
        writeError(req, 401, 'UNAUTHORIZED', '缺少或错误的会话 token');
        return;
      }
      if (hasProtoMismatch(req)) {
        writeError(req, 426, 'PROTO_MISMATCH', '协议版本不一致');
        return;
      }

      switch (path) {
        case '/v2/index':
          await _index(req);
          return;
        case '/v2/resume':
          await _resume(req);
          return;
        case '/v2/resume/batch':
          await _resumeBatch(req);
          return;
        case '/v2/upload':
          await _upload(req);
          return;
        case '/v2/log':
          await _log(req);
          return;
        case '/v2/disconnect':
          _disconnect(req, token);
          return;
        default:
          writeError(req, 404, 'NOT_FOUND', '未知端点');
          return;
      }
    } catch (e) {
      try {
        writeError(req, 500, 'IO_ERROR', '$e');
      } catch (_) {
        // 响应可能已发送，忽略二次写入异常。
      }
    }
  }

  void _hello(HttpRequest req) {
    if (hasProtoMismatch(req)) {
      writeError(req, 426, 'PROTO_MISMATCH', '协议版本不一致');
      return;
    }
    writeJson(req, {
      'proto': AppConstants.protoVersion,
      'app': AppConstants.appTag,
      'version': AppConstants.currentVersion,
      'minPeer': AppConstants.minPeer,
      'session': session,
      'device': {
        'id': deviceId,
        'name': deviceName,
        'role': 'android',
      },
    });
  }

  Future<void> _pair(HttpRequest req) async {
    if (hasProtoMismatch(req)) {
      writeError(req, 426, 'PROTO_MISMATCH', '协议版本不一致');
      return;
    }
    if (busy || _uploading) {
      writeError(req, 409, 'BUSY', '正在同步中');
      return;
    }
    final body = await readJsonObject(req);
    if (body == null) {
      writeError(req, 400, 'BAD_REQUEST', '请求体非法');
      return;
    }
    if ((body['proto'] as num?)?.toInt() != AppConstants.protoVersion) {
      writeError(req, 426, 'PROTO_MISMATCH', '协议版本不一致');
      return;
    }
    if (body['role'] != 'pc') {
      writeError(req, 400, 'BAD_REQUEST', '角色不匹配');
      return;
    }

    final remote = req.connectionInfo?.remoteAddress.address ?? '';
    final requester = PeerDevice.fromHello(body, remote);
    if (requester.id.isEmpty) {
      writeError(req, 400, 'BAD_REQUEST', '设备 id 缺失');
      return;
    }

    final peerToken = body['token'] as String? ?? '';
    final token = _tokens.issueFor(requester.id);
    onPeerPaired(requester.copyWith(connected: true), peerToken);

    writeJson(req, {
      'ok': true,
      'token': token,
      'session': session,
      'device': {
        'id': deviceId,
        'name': deviceName,
        'role': 'android',
      },
    });
  }

  Future<void> _index(HttpRequest req) async {
    if (busy || _uploading) {
      writeError(req, 409, 'BUSY', '正在同步中');
      return;
    }
    final name = req.uri.queryParameters['name'] ?? '';
    final mapping = _mapping(name);
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射「$name」不存在');
      return;
    }
    final index = await LocalIndexService.scan(mapping.destPath);
    final files = index.values.map((e) => e.toJson()).toList()
      ..sort((a, b) => (a['p'] as String).compareTo(b['p'] as String));
    writeJson(req, {
      'ok': true,
      'name': mapping.name,
      'files': files,
    });
  }

  Future<void> _resume(HttpRequest req) async {
    if (req.method != 'GET') {
      writeError(req, 400, 'BAD_REQUEST', '方法不支持');
      return;
    }
    if (busy || _uploading) {
      writeError(req, 409, 'BUSY', '正在同步中');
      return;
    }
    final name = req.uri.queryParameters['name'] ?? '';
    final rel = req.uri.queryParameters['path'] ?? '';
    final size = int.tryParse(req.uri.queryParameters['size'] ?? '');
    final mtime = int.tryParse(req.uri.queryParameters['mtime'] ?? '');
    final mapping = _mapping(name);
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射「$name」不存在');
      return;
    }
    if (!isValidRelPath(rel) || size == null || size < 0 || mtime == null) {
      writeError(req, 400, 'PATH_INVALID', '路径或大小非法');
      return;
    }
    final offset =
        await PartStore.currentOffset(mapping.destPath, rel, size, mtime);
    writeJson(req, {'ok': true, 'offset': offset});
  }

  /// 批量查询续传偏移：一次请求返回整批文件的已接收字节数。
  ///
  /// 请求体：`{name, items:[{p,s,m}]}`；响应：`{ok, offsets:{path:offset}}`。
  Future<void> _resumeBatch(HttpRequest req) async {
    if (req.method != 'POST') {
      writeError(req, 400, 'BAD_REQUEST', '方法不支持');
      return;
    }
    if (busy || _uploading) {
      writeError(req, 409, 'BUSY', '正在同步中');
      return;
    }
    final body = await readJsonObject(req);
    if (body == null) {
      writeError(req, 400, 'BAD_REQUEST', '请求体非法');
      return;
    }
    final mapping = _mapping(body['name'] as String? ?? '');
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射不存在');
      return;
    }
    final items = body['items'];
    if (items is! List || items.length > 5000) {
      writeError(req, 400, 'BAD_REQUEST', '文件列表非法');
      return;
    }

    final offsets = <String, int>{};
    for (final raw in items) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final rel = item['p'] as String? ?? '';
      final size = (item['s'] as num?)?.toInt();
      final mtime = (item['m'] as num?)?.toInt();
      if (!isValidRelPath(rel) || size == null || size < 0 || mtime == null) {
        continue;
      }
      offsets[rel] =
          await PartStore.currentOffset(mapping.destPath, rel, size, mtime);
    }
    writeJson(req, {'ok': true, 'offsets': offsets});
  }

  Future<void> _upload(HttpRequest req) async {
    if (req.method != 'POST') {
      writeError(req, 400, 'BAD_REQUEST', '方法不支持');
      return;
    }
    final name = req.uri.queryParameters['name'] ?? '';
    final rel = req.uri.queryParameters['path'] ?? '';
    final size = int.tryParse(req.uri.queryParameters['size'] ?? '');
    final mtime = int.tryParse(req.uri.queryParameters['mtime'] ?? '') ?? 0;
    final mapping = _mapping(name);
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射「$name」不存在');
      return;
    }
    if (!isValidRelPath(rel) || size == null || size < 0) {
      writeError(req, 400, 'PATH_INVALID', '路径或大小非法');
      return;
    }

    final dst = LocalIndexService.safeFile(mapping.destPath, rel);
    if (dst == null) {
      writeError(req, 400, 'PATH_INVALID', '路径非法');
      return;
    }
    if (_uploading || busy) {
      writeError(req, 409, 'BUSY', '已有同步任务正在进行');
      return;
    }
    _uploading = true;

    try {
      final root = mapping.destPath;
      final part = PartStore.partFile(root, rel);
      final currentOffset =
          await PartStore.currentOffset(root, rel, size, mtime);

      final offsetHeader = req.headers.value('X-Offset');
      final start =
          offsetHeader == null ? 0 : (int.tryParse(offsetHeader) ?? -1);
      if (start < 0 || start != currentOffset) {
        writeError(req, 416, 'RANGE_INVALID', '续传偏移不匹配');
        return;
      }
      if (req.contentLength >= 0 && req.contentLength != size - start) {
        writeError(req, 416, 'RANGE_INVALID', '请求体长度与剩余字节不一致');
        return;
      }

      await dst.parent.create(recursive: true);
      await part.parent.create(recursive: true);

      if (start == 0) {
        await PartStore.discard(root, rel);
      }
      await PartStore.writeMeta(
        root,
        rel,
        PartMeta(path: rel, size: size, mtime: mtime),
      );

      final sink = part.openWrite(mode: FileMode.append);
      var received = start;
      try {
        // 通过 addStream 维持背压，避免大文件写入时整段数据堆积在内存。
        await sink.addStream(req.map((chunk) {
          received += chunk.length;
          return chunk;
        }));
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (received != size) {
        // 数据不完整：保留分片，允许下次续传。
        writeError(req, 409, 'INCOMPLETE', '数据不完整，已保留分片');
        return;
      }

      // 完整性以「偏移 + 最终字节数」保证：数据不完整时不会被改名到目标路径。
      try {
        await part.rename(dst.path);
      } on FileSystemException {
        // 目标已存在且平台不允许覆盖时，先删除再落盘。
        if (await dst.exists()) await dst.delete();
        await part.rename(dst.path);
      }
      if (mtime > 0) {
        try {
          await dst.setLastModified(
            DateTime.fromMillisecondsSinceEpoch(mtime),
          );
        } catch (_) {}
      }
      await PartStore.discard(root, rel);
      writeJson(req, {'ok': true, 'size': size});
    } catch (e) {
      if (_isNoSpace(e)) {
        writeError(req, 507, 'NO_SPACE', '目标磁盘空间不足');
      } else {
        writeError(req, 500, 'IO_ERROR', '$e');
      }
    } finally {
      _uploading = false;
    }
  }

  Future<void> _log(HttpRequest req) async {
    final body = await readJsonObject(req);
    if (body == null) {
      writeError(req, 400, 'BAD_REQUEST', '请求体非法');
      return;
    }
    await onSyncLog(
      body['name'] as String? ?? '',
      (body['count'] as num?)?.toInt() ?? 0,
      (body['bytes'] as num?)?.toInt() ?? 0,
      (body['files'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
    writeJson(req, {'ok': true});
  }

  void _disconnect(HttpRequest req, String token) {
    final id = _tokens.take(token);
    if (id == null || id.isEmpty) {
      writeError(req, 401, 'UNAUTHORIZED', '会话不存在');
      return;
    }
    onDisconnect(id);
    writeJson(req, {'ok': true});
  }

  SyncMapping? _mapping(String name) {
    for (final m in config.config.mappings) {
      if (m.name == name) return m;
    }
    return null;
  }

  bool _isNoSpace(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('no space left') ||
        msg.contains('enospc') ||
        msg.contains('errno = 28');
  }
}
