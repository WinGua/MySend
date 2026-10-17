import 'dart:convert';
import 'dart:io';

import '../../models/device_info.dart';
import '../../models/sync_mapping.dart';
import '../local_index_service.dart';

/// 发送端（PC）HTTP 服务。
///
/// 接口：
/// - POST /pair-request            接收端发起连接确认
/// - GET  /index?mapping=<name>     指定映射源目录的完整文件索引
/// - GET  /file?mapping=<name>&path=<rel>  下载单个文件
///
/// 安全说明：当前为局域网内明文 HTTP（v1 简化）；后续可在此处挂载自签 TLS，
/// 只需在 [start] 中为 [HttpServer.bind] 传入 [SecurityContext] 即可。
class SenderServer {
  final int port;
  final List<SyncMapping> Function() mappingsProvider;
  final Future<bool> Function(PeerDevice requester) onPairRequest;
  final Future<void> Function(String name, int count, int bytes, List<String> files)?
      onSyncLog;

  HttpServer? _server;

  SenderServer({
    required this.port,
    required this.mappingsProvider,
    required this.onPairRequest,
    this.onSyncLog,
  });

  bool get running => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  void _handle(HttpRequest req) async {
    try {
      switch (req.uri.path) {
        case '/pair-request':
          await _handlePair(req);
          break;
        case '/index':
          await _handleIndex(req);
          break;
        case '/file':
          await _handleFile(req);
          break;
        case '/sync-log':
          await _handleSyncLog(req);
          break;
        default:
          _writeJson(req, {'error': 'not found'}, status: 404);
      }
    } catch (e) {
      _writeJson(req, {'error': '$e'}, status: 500);
    }
  }

  Future<void> _handlePair(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    try {
      final e = jsonDecode(body) as Map<String, dynamic>;
      final remote = req.connectionInfo?.remoteAddress.address ?? '';
      final requester = PeerDevice.fromEnvelope(e, remote);
      final accepted = await onPairRequest(requester);
      _writeJson(req, {'accepted': accepted});
    } catch (_) {
      _writeJson(req, {'accepted': false}, status: 400);
    }
  }

  Future<void> _handleIndex(HttpRequest req) async {
    final name = req.uri.queryParameters['mapping'] ?? '';
    final mapping = _findMapping(name);
    if (mapping == null) {
      _writeJson(req, {'error': 'unknown mapping', 'files': []}, status: 404);
      return;
    }
    final index = await LocalIndexService.scan(mapping.sourcePath);
    final files = index.values.map((e) => e.toJson()).toList();
    _writeJson(req, {
      'name': mapping.name,
      'root': mapping.sourcePath,
      'files': files,
    });
  }

  Future<void> _handleFile(HttpRequest req) async {
    final name = req.uri.queryParameters['mapping'] ?? '';
    final rel = req.uri.queryParameters['path'] ?? '';
    final mapping = _findMapping(name);
    if (mapping == null) {
      _writeJson(req, {'error': 'unknown mapping'}, status: 404);
      return;
    }
    final file = LocalIndexService.safeFile(mapping.sourcePath, rel);
    if (file == null || !await file.exists()) {
      _writeJson(req, {'error': 'file not found'}, status: 404);
      return;
    }
    final length = await file.length();
    req.response.statusCode = 200;
    req.response.headers.set('Content-Type', 'application/octet-stream');
    req.response.headers.set('Content-Length', '$length');
    try {
      await req.response.addStream(file.openRead());
    } catch (_) {
      // 连接中断，忽略。
    }
  }

  Future<void> _handleSyncLog(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    try {
      final e = jsonDecode(body) as Map<String, dynamic>;
      await onSyncLog?.call(
        e['name'] as String? ?? '',
        (e['count'] as num?)?.toInt() ?? 0,
        (e['bytes'] as num?)?.toInt() ?? 0,
        (e['files'] as List<dynamic>? ?? const [])
            .map((x) => x.toString())
            .toList(),
      );
      _writeJson(req, {'ok': true});
    } catch (_) {
      _writeJson(req, {'ok': false}, status: 400);
    }
  }

  SyncMapping? _findMapping(String name) {
    for (final m in mappingsProvider()) {
      if (m.name == name) return m;
    }
    return null;
  }

  void _writeJson(HttpRequest req, Map<String, dynamic> body, {int status = 200}) {
    req.response.statusCode = status;
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.write(jsonEncode(body));
    req.response.close();
  }
}