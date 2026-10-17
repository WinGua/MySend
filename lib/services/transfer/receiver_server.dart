import 'dart:convert';
import 'dart:io';

import '../../models/device_info.dart';
import '../../models/sync_mapping.dart';
import '../local_index_service.dart';

/// 接收端（Android）HTTP 服务。
///
/// 接口：
/// - POST /pair-request              发送端发起连接确认
/// - GET  /dest-index?mapping=<name>  指定映射目标目录的完整索引
/// - POST /upload?mapping=<name>&path=<rel>  接收推送过来的单个文件
class ReceiverServer {
  final int port;
  final List<SyncMapping> Function() mappingsProvider;
  final Future<bool> Function(PeerDevice requester) onPairRequest;

  HttpServer? _server;

  ReceiverServer({
    required this.port,
    required this.mappingsProvider,
    required this.onPairRequest,
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
        case '/dest-index':
          await _handleIndex(req);
          break;
        case '/upload':
          await _handleUpload(req);
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
    final index = await LocalIndexService.scan(mapping.destPath);
    final files = index.values.map((e) => e.toJson()).toList();
    _writeJson(req, {'files': files});
  }

  Future<void> _handleUpload(HttpRequest req) async {
    final name = req.uri.queryParameters['mapping'] ?? '';
    final rel = req.uri.queryParameters['path'] ?? '';
    final mapping = _findMapping(name);
    if (mapping == null) {
      _writeJson(req, {'error': 'unknown mapping'}, status: 404);
      return;
    }
    final file = LocalIndexService.safeFile(mapping.destPath, rel);
    if (file == null) {
      _writeJson(req, {'error': 'bad path'}, status: 400);
      return;
    }
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    try {
      await sink.addStream(req).timeout(const Duration(minutes: 10));
    } finally {
      await sink.close();
    }
    _writeJson(req, {'ok': true});
  }

  SyncMapping? _findMapping(String name) {
    for (final m in mappingsProvider()) {
      if (m.name == name) return m;
    }
    return null;
  }

  void _writeJson(HttpRequest req, Map<String, dynamic> body, {int status = 200}) {
    req.response.statusCode = status;
    // 明确关闭连接，避免 keep-alive 悬挂导致发送端在连续传输时假死。
    req.response.headers.set(HttpHeaders.connectionHeader, 'close');
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.write(jsonEncode(body));
    req.response.close();
  }
}