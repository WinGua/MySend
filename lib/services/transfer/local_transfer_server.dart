import 'dart:io';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../models/device_info.dart';
import '../../models/sync_mapping.dart';
import '../../storage/config_repository.dart';
import '../local_index_service.dart';
import 'part_store.dart';
import 'protocol.dart';

/// 两端统一的 HTTP 服务（协议 v2）。
///
/// 电脑端与安卓端具备完全相同的端点，因此任意一端都能作为发送方或接收方：
/// - GET  /v2/hello
/// - POST /v2/pair
/// - GET  /v2/index      查询本机映射根索引
/// - GET  /v2/file       下载本机文件（支持 Range 续传）
/// - GET  /v2/resume     查询本机已接收偏移
/// - POST /v2/resume/batch 批量查询已接收偏移
/// - POST /v2/upload     分片续传上传（原子落盘）
/// - POST /v2/log        接收对端同步日志
/// - POST /v2/disconnect
class LocalTransferServer implements TransferServer {
  final int preferredPort;
  final ConfigRepository config;

  /// 本机是否为电脑端：仅用于角色标识与选择映射的本地根目录。
  final bool isSender;
  final String session;

  /// 配对成功时回调，同时带回对端签发的 token（供本机反向调用）。
  final void Function(PeerDevice peer, String peerToken) onPeerPaired;

  /// 收到对端推送的同步日志。
  final Future<void> Function(SyncLogReport report) onSyncLog;

  /// 对端主动断开。
  final void Function(String deviceId) onDisconnect;

  /// 当前是否有同步任务占用（同一设备同一时刻只允许一个任务）。
  @override
  bool busy = false;

  /// 是否有上传正在写入分片，用于拒绝并发上传。
  bool _uploading = false;

  HttpServer? _server;
  final TokenStore _tokens = TokenStore();

  LocalTransferServer({
    required this.preferredPort,
    required this.config,
    required this.isSender,
    required this.session,
    required this.onPeerPaired,
    required this.onSyncLog,
    required this.onDisconnect,
  });

  @override
  int get port => _server?.port ?? preferredPort;

  @override
  bool get running => _server != null;

  String get _role => isSender ? 'pc' : 'android';

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
        case '/v2/file':
          await _file(req);
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
    final cfg = config.config;
    writeJson(req, {
      'proto': AppConstants.protoVersion,
      'app': AppConstants.appTag,
      'version': AppConstants.currentVersion,
      'minPeer': AppConstants.minPeer,
      'session': session,
      'device': {
        'id': cfg.deviceId,
        'name': cfg.deviceName,
        'role': _role,
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
    final peerRole = body['role'] as String? ?? '';
    // 只接受对端角色，避免同角色设备互连（电脑 ↔ 电脑、安卓 ↔ 安卓）。
    if (peerRole != 'pc' && peerRole != 'android') {
      writeError(req, 400, 'BAD_REQUEST', '角色不匹配');
      return;
    }
    if (peerRole == _role) {
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

    final cfg = config.config;
    writeJson(req, {
      'ok': true,
      'token': token,
      'session': session,
      'device': {
        'id': cfg.deviceId,
        'name': cfg.deviceName,
        'role': _role,
      },
    });
  }

  Future<void> _index(HttpRequest req) async {
    if (busy || _uploading) {
      writeError(req, 409, 'BUSY', '正在同步中');
      return;
    }
    final mapping = _mapping(req.uri.queryParameters['name'] ?? '');
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射不存在');
      return;
    }
    final root = mapping.localRoot(isSender);
    if (root.isEmpty) {
      writeError(req, 409, 'MAPPING_NOT_CONFIGURED', '映射未配置本机目录');
      return;
    }
    final index = await LocalIndexService.scan(root);
    final files = index.values.map((e) => e.toJson()).toList()
      ..sort((a, b) => (a['p'] as String).compareTo(b['p'] as String));
    writeJson(req, {
      'ok': true,
      'name': mapping.name,
      'files': files,
    });
  }

  Future<void> _file(HttpRequest req) async {
    if (busy || _uploading) {
      writeError(req, 409, 'BUSY', '正在同步中');
      return;
    }
    final mapping = _mapping(req.uri.queryParameters['name'] ?? '');
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射不存在');
      return;
    }
    final root = mapping.localRoot(isSender);
    if (root.isEmpty) {
      writeError(req, 409, 'MAPPING_NOT_CONFIGURED', '映射未配置本机目录');
      return;
    }
    final rel = req.uri.queryParameters['path'] ?? '';
    final target = LocalIndexService.safeFile(root, rel);
    if (target == null) {
      writeError(req, 400, 'PATH_INVALID', '路径非法');
      return;
    }
    if (!await target.exists()) {
      writeError(req, 404, 'FILE_NOT_FOUND', '文件不存在');
      return;
    }

    final total = await target.length();
    var start = 0;
    var status = 200;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d+)-$', caseSensitive: false)
          .firstMatch(range.trim());
      final parsed = int.tryParse(match?.group(1) ?? '');
      if (parsed == null || parsed < 0 || parsed >= total) {
        writeError(req, 416, 'RANGE_INVALID', 'Range 起点越界');
        return;
      }
      start = parsed;
      status = 206;
    }

    final res = req.response;
    res.statusCode = status;
    res.headers.set(HttpHeaders.connectionHeader, 'close');
    res.headers.contentType = ContentType('application', 'octet-stream');
    res.headers.set('Accept-Ranges', 'bytes');
    res.headers.contentLength = total - start;
    if (status == 206) {
      res.headers.set(
        'Content-Range',
        'bytes $start-${total - 1}/$total',
      );
    }
    try {
      await res.addStream(target.openRead(start));
    } catch (_) {
      // 对端中断连接，忽略。
    }
    try {
      await res.close();
    } catch (_) {}
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
    final mapping = _mapping(req.uri.queryParameters['name'] ?? '');
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射不存在');
      return;
    }
    final rel = req.uri.queryParameters['path'] ?? '';
    final size = int.tryParse(req.uri.queryParameters['size'] ?? '');
    final mtime = int.tryParse(req.uri.queryParameters['mtime'] ?? '');
    if (!isValidRelPath(rel) || size == null || size < 0 || mtime == null) {
      writeError(req, 400, 'PATH_INVALID', '路径或大小非法');
      return;
    }
    final root = mapping.localRoot(isSender);
    if (root.isEmpty) {
      writeError(req, 409, 'MAPPING_NOT_CONFIGURED', '映射未配置本机目录');
      return;
    }
    final offset = await PartStore.currentOffset(
      root,
      rel,
      size,
      mtime,
    );
    writeJson(req, {'ok': true, 'offset': offset});
  }

  /// 批量查询续传偏移：请求体 `{name, items:[{p,s,m}]}`。
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

    final root = mapping.localRoot(isSender);
    if (root.isEmpty) {
      writeError(req, 409, 'MAPPING_NOT_CONFIGURED', '映射未配置本机目录');
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
      offsets[rel] = await PartStore.currentOffset(root, rel, size, mtime);
    }
    writeJson(req, {'ok': true, 'offsets': offsets});
  }

  Future<void> _upload(HttpRequest req) async {
    if (req.method != 'POST') {
      writeError(req, 400, 'BAD_REQUEST', '方法不支持');
      return;
    }
    final mapping = _mapping(req.uri.queryParameters['name'] ?? '');
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射不存在');
      return;
    }
    final rel = req.uri.queryParameters['path'] ?? '';
    final size = int.tryParse(req.uri.queryParameters['size'] ?? '');
    final mtime = int.tryParse(req.uri.queryParameters['mtime'] ?? '') ?? 0;
    if (!isValidRelPath(rel) || size == null || size < 0) {
      writeError(req, 400, 'PATH_INVALID', '路径或大小非法');
      return;
    }

    final root = mapping.localRoot(isSender);
    if (root.isEmpty) {
      writeError(req, 409, 'MAPPING_NOT_CONFIGURED', '映射未配置本机目录');
      return;
    }
    final dst = LocalIndexService.safeFile(root, rel);
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
      // 双向同步只补新增：目标已存在时绝不覆盖。
      if (await dst.exists()) {
        writeError(req, 409, 'ALREADY_EXISTS', '目标文件已存在，已跳过');
        return;
      }
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
    // 大目录的文件名清单可能超过默认 1 MB，这里放宽到 8 MB。
    final body = await readJsonObject(req, maxBytes: 8 * 1024 * 1024);
    if (body == null) {
      writeError(req, 400, 'BAD_REQUEST', '请求体非法');
      return;
    }
    // 对端报文站在对端视角，本机保存前需要互换发送/接收。
    await onSyncLog(SyncLogReport.fromJson(body).mirrored());
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
