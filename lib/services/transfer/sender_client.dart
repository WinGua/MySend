import 'dart:convert';
import 'dart:io';

import '../../models/file_entry.dart';

/// 发送端（PC）HTTP 客户端，向接收端 Android 查询索引 / 推送文件 / 发起配对。
class SenderClient {
  final String address;
  final int port;

  SenderClient({required this.address, required this.port});

  HttpClient _client() {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, p) => true;
    client.connectionTimeout = const Duration(seconds: 10);
    return client;
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: address, port: port, path: path, queryParameters: query);

  /// 向对端发起配对请求，返回是否被接受。
  Future<bool> sendPairRequest(Map<String, dynamic> selfInfo) async {
    final client = _client();
    try {
      final req = await client.postUrl(_uri('/pair-request'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(selfInfo));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final j = jsonDecode(text) as Map<String, dynamic>;
      return j['accepted'] == true;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// 拉取接收端某个映射的目标目录索引（用于 PC 端对比）。
  Future<List<FileEntry>> getDestIndex(String mappingName) async {
    final client = _client();
    try {
      final req = await client.getUrl(_uri('/dest-index', {'mapping': mappingName}));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final j = jsonDecode(text) as Map<String, dynamic>;
      final files = (j['files'] as List<dynamic>? ?? [])
          .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      return files;
    } finally {
      client.close();
    }
  }

  /// 上传单个文件到接收端对应目录。
  Future<void> uploadFile(
    String mappingName,
    String relativePath,
    String sourceFilePath, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final file = File(sourceFilePath);
    final length = await file.length();
    final client = _client();
    try {
      final req = await client.postUrl(
        _uri('/upload', {'mapping': mappingName, 'path': relativePath}),
      );
      req.headers.contentType = ContentType('application', 'octet-stream');
      req.contentLength = length;
      int sent = 0;
      await for (final chunk in file.openRead()) {
        req.add(chunk);
        sent += chunk.length;
        onProgress?.call(sent, length);
      }
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('上传失败: ${res.statusCode} $relativePath');
      }
      await res.drain<void>();
    } finally {
      client.close();
    }
  }
}