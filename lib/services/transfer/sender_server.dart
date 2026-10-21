import 'dart:io';

import '../../core/constants.dart';
import '../../models/device_info.dart';
import '../../models/sync_mapping.dart';
import '../../storage/config_repository.dart';
import '../local_index_service.dart';
import 'protocol.dart';

/// PC 端 HTTP 服务（协议 v2）。
///
/// - GET  /v2/hello
/// - POST /v2/pair
/// - GET  /v2/index     查询源目录索引
/// - GET  /v2/file      下载文件（支持 Range 续传）
/// - POST /v2/log       接收对端同步日志
/// - POST /v2/disconnect
class SenderServer implements TransferServer {
  final int preferredPort;
  final ConfigRepository config;
  final String session;

  /// 配对成功时回调，同时带回对端签发的 token（供本机反向调用）。
  final void Function(PeerDevice peer, String peerToken) onPeerPaired;

  /// 收到对端推送的同步日志。
  final Future<void> Function(String name, int count, int bytes, List<String> files)
      onSyncLog;

  /// 对端主动断开。
  final void Function(String deviceId) onDisconnect;

  HttpServer? _server;
  final TokenStore _tokens = TokenStore();

  SenderServer({
    required this.preferredPort,
    required this.config,
    required this.session,
    required this.onPeerPaired,
    required this.onSyncLog,
    required this.onDisconnect,
  });

  @override
  int get port => _server?.port ?? preferredPort;

  @override
  bool get running => _server != null;

  @override
  bool busy = false;

  @override
  String issueTokenFor(String deviceId) => _tokens.issueFor(deviceId);

  @override
  void revokeFor(String deviceId) => _tokens.revokeFor(deviceId);

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } catch (_) {
      // 首选端口被占用时退回系统分配端口，并在 hello 中声明实际端口。
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
        'role': 'pc',
      },
    });
  }

  Future<void> _pair(HttpRequest req) async {
    if (hasProtoMismatch(req)) {
      writeError(req, 426, 'PROTO_MISMATCH', '协议版本不一致');
      return;
    }
    if (busy) {
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
    if (body['role'] != 'android') {
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
        'role': 'pc',
      },
    });
  }

  Future<void> _index(HttpRequest req) async {
    if (busy) {
      writeError(req, 409, 'BUSY', '正在同步中');
      return;
    }
    final name = req.uri.queryParameters['name'] ?? '';
    final mapping = _mapping(name);
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射「$name」不存在');
      return;
    }
    final index = await LocalIndexService.scan(mapping.sourcePath);
    final files = index.values.map((e) => e.toJson()).toList()
      ..sort((a, b) => (a['p'] as String).compareTo(b['p'] as String));
    writeJson(req, {
      'ok': true,
      'name': mapping.name,
      'files': files,
    });
  }

  Future<void> _file(HttpRequest req) async {
    if (busy) {
      writeError(req, 409, 'BUSY', '正在同步中');
      return;
    }
    final name = req.uri.queryParameters['name'] ?? '';
    final rel = req.uri.queryParameters['path'] ?? '';
    final mapping = _mapping(name);
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射「$name」不存在');
      return;
    }
    final target = LocalIndexService.safeFile(mapping.sourcePath, rel);
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
    final deviceId = _tokens.take(token);
    if (deviceId == null || deviceId.isEmpty) {
      writeError(req, 401, 'UNAUTHORIZED', '会话不存在');
      return;
    }
    onDisconnect(deviceId);
    writeJson(req, {'ok': true});
  }

  SyncMapping? _mapping(String name) {
    for (final m in config.config.mappings) {
      if (m.name == name) return m;
    }
    return null;
  }
}
