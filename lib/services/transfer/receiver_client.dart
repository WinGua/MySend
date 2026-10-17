import 'dart:convert';
import 'dart:io';

import '../../models/file_entry.dart';

/// 接收端（Android）HTTP 客户端，向发送端 PC 拉取文件 / 发起配对。
///
/// 每个请求都用独立的 [HttpClient] 并在结束后立即 `close(force: true)`，
/// 不依赖 HTTP keep-alive 连接复用（见 [SenderClient] 说明）。
class ReceiverClient {
  final String address;
  final int port;

  ReceiverClient({required this.address, required this.port});

  HttpClient _create() {
    final client = HttpClient();
    // 若后续启用自签 TLS，可在此钉扎证书。
    client.badCertificateCallback = (cert, host, p) => true;
    client.connectionTimeout = const Duration(seconds: 10);
    client.idleTimeout = const Duration(seconds: 60);
    return client;
  }

  /// 兼容旧调用点；内部连接已即时关闭，无需再释放。
  void close() {}

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
      http.close(force: true);
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
      http.close(force: true);
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
    final http = _create();
    try {
      final req = await http.getUrl(
        _uri('/file', {'mapping': mappingName, 'path': relativePath}),
      );
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('下载失败: ${res.statusCode} $relativePath');
      }
      final total = res.contentLength;
      final file = File(destFilePath);
      await file.parent.create(recursive: true);
      final sink = file.openWrite();
      int received = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
      if (mtimeMs != null) {
        try {
          await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(mtimeMs));
        } catch (_) {}
      }
    } finally {
      http.close(force: true);
    }
  }
}