import 'dart:convert';
import 'dart:io';

import '../../models/file_entry.dart';

/// 接收端（Android）HTTP 客户端，向发送端 PC 拉取文件 / 发起配对。
///
/// 文件下载复用单个常驻 [HttpClient]（避免安卓端每文件新建连接池的开销），
/// 但每个请求设置 `persistentConnection = false`，配合服务端 `Connection: close`
/// 逐文件独立短连接，避免 keep-alive 悬挂导致「连续下载多文件后卡住」。
class ReceiverClient {
  final String address;
  final int port;

  ReceiverClient({required this.address, required this.port});

  HttpClient? _http;

  HttpClient _create() {
    final client = HttpClient();
    // 若后续启用自签 TLS，可在此钉扎证书。
    client.badCertificateCallback = (cert, host, p) => true;
    client.connectionTimeout = const Duration(seconds: 10);
    client.idleTimeout = const Duration(seconds: 60);
    return client;
  }

  /// 复用一个常驻 [HttpClient]（仅在需要时创建），
  /// 避免每个文件新建/销毁连接池在安卓端造成的描述符与线程开销。
  HttpClient _ensure() => _http ??= _create();

  /// 关闭常驻连接池；一次性请求（配对 / 索引 / 日志）仍各自使用独立短连接。
  void close() {
    _http?.close(force: true);
    _http = null;
  }

  /// 推送一次同步日志到对端，让对端也留存该次同步记录。
  Future<void> sendSyncLog({
    required String name,
    required int fileCount,
    required int totalBytes,
    required List<String> files,
  }) async {
    final http = _create();
    try {
      final req = await http.postUrl(_uri('/sync-log'));
      req.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      req.write(jsonEncode({
        'name': name,
        'count': fileCount,
        'bytes': totalBytes,
        'files': files,
      }));
      final res = await req.close();
      await res.drain<void>();
    } finally {
      http.close();
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: address, port: port, path: path, queryParameters: query);

  /// 向对端发起配对请求，返回是否被接受。
  Future<bool> sendPairRequest(Map<String, dynamic> selfInfo) async {
    final http = _create();
    try {
      final req = await http.postUrl(_uri('/pair-request'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(selfInfo));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final j = jsonDecode(text) as Map<String, dynamic>;
      return j['accepted'] == true;
    } catch (_) {
      return false;
    } finally {
      http.close();
    }
  }

  /// 拉取某个映射在发送端的完整索引。
  Future<List<FileEntry>> getIndex(String mappingName) async {
    final http = _create();
    try {
      final req = await http.getUrl(_uri('/index', {'mapping': mappingName}));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final j = jsonDecode(text) as Map<String, dynamic>;
      return (j['files'] as List<dynamic>? ?? [])
          .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } finally {
      http.close();
    }
  }

  /// 下载单个文件到 [destFilePath]。
  Future<void> downloadFile(
    String mappingName,
    String relativePath,
    String destFilePath, {
    int? mtimeMs,
    void Function(int received, int total)? onProgress,
  }) async {
    final http = _ensure();
    final req = await http.getUrl(
      _uri('/file', {'mapping': mappingName, 'path': relativePath}),
    );
    req.persistentConnection = false;
    final res = await req.close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('下载失败: ${res.statusCode} $relativePath');
    }
    final total = res.contentLength;
    final file = File(destFilePath);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    int received = 0;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      rethrow;
    }
    if (mtimeMs != null) {
      try {
        await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(mtimeMs));
      } catch (_) {}
    }
  }
}