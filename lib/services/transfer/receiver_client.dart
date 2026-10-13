import 'dart:convert';
import 'dart:io';

import '../../models/file_entry.dart';

/// 接收端（Android）HTTP 客户端，向发送端 PC 拉取文件。
class ReceiverClient {
  final String address;
  final int port;

  ReceiverClient({required this.address, required this.port});

  HttpClient _client() {
    final client = HttpClient();
    // 预留：若后续启用自签 TLS，可在此接受并钉扎证书。
    client.badCertificateCallback = (cert, host, p) => true;
    client.connectionTimeout = const Duration(seconds: 10);
    return client;
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: address, port: port, path: path, queryParameters: query);

  /// 获取发送端设备信息。
  Future<Map<String, dynamic>> getInfo() async {
    final client = _client();
    try {
      final req = await client.getUrl(_uri('/info'));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// 获取发送端已配置的映射名列表。
  Future<List<String>> getMappingNames() async {
    final client = _client();
    try {
      final req = await client.getUrl(_uri('/mappings'));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final j = jsonDecode(text) as Map<String, dynamic>;
      final list = (j['mappings'] as List<dynamic>? ?? [])
          .map((e) => (e as Map<String, dynamic>)['name'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      return list;
    } finally {
      client.close();
    }
  }

  /// 拉取某个映射在发送端的完整索引（相对路径列表）。
  Future<List<FileEntry>> getIndex(String mappingName) async {
    final client = _client();
    try {
      final req = await client.getUrl(_uri('/index', {'mapping': mappingName}));
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

  /// 下载单个文件到 [destFilePath]。
  /// [onProgress] 会回调已接收字节数与总字节数。
  Future<void> downloadFile(
    String mappingName,
    String relativePath,
    String destFilePath, {
    int? mtimeMs,
    void Function(int received, int total)? onProgress,
  }) async {
    final client = _client();
    try {
      final req = await client.getUrl(
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
      // 回写源文件的修改时间，避免二次对比时被误判为「变更」。
      if (mtimeMs != null) {
        try {
          await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(mtimeMs));
        } catch (_) {}
      }
    } finally {
      client.close();
    }
  }
}