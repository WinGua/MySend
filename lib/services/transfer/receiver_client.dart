import 'dart:convert';
import 'dart:io';

import '../../models/file_entry.dart';

/// 接收端（Android）HTTP 客户端，向发送端 PC 拉取文件 / 发起配对。
///
/// 复用同一个 [HttpClient]（keep-alive），避免每个文件都新建连接造成
/// TIME_WAIT / 端口资源累积，进而导致「连续传输多文件后中途卡住」。
class ReceiverClient {
  final String address;
  final int port;

  HttpClient? _http;

  ReceiverClient({required this.address, required this.port});

  HttpClient get _client => _http ??= _create();

  HttpClient _create() {
    final client = HttpClient();
    // 预留：若后续启用自签 TLS，可在此接受并钉扎证书。
    client.badCertificateCallback = (cert, host, p) => true;
    client.connectionTimeout = const Duration(seconds: 10);
    client.idleTimeout = const Duration(seconds: 60);
    return client;
  }

  /// 关闭底层连接（一次同步任务结束后释放）。
  void close() {
    _http?.close(force: true);
    _http = null;
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: address, port: port, path: path, queryParameters: query);

  /// 向对端发起配对请求，返回是否被接受。
  Future<bool> sendPairRequest(Map<String, dynamic> selfInfo) async {
    try {
      final req = await _client.postUrl(_uri('/pair-request'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(selfInfo));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final j = jsonDecode(text) as Map<String, dynamic>;
      return j['accepted'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 拉取某个映射在发送端的完整索引（相对路径列表）。
  Future<List<FileEntry>> getIndex(String mappingName) async {
    final req = await _client.getUrl(_uri('/index', {'mapping': mappingName}));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final j = jsonDecode(text) as Map<String, dynamic>;
    final files = (j['files'] as List<dynamic>? ?? [])
        .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return files;
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
    final req = await _client.getUrl(
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
    // 回写源文件的修改时间，保留文件的原始时间戳。
    if (mtimeMs != null) {
      try {
        await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(mtimeMs));
      } catch (_) {}
    }
  }
}