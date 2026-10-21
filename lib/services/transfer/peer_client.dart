import 'dart:convert';
import 'dart:io';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../models/device_info.dart';
import '../../models/file_entry.dart';
import '../../models/sync_mapping.dart';

/// 协议层可预期的错误（状态码 + 错误码 + 可展示信息）。
class TransferException implements Exception {
  final int status;
  final String code;
  final String message;

  const TransferException(this.status, this.code, this.message);

  @override
  String toString() => message.isEmpty ? 'HTTP $status' : message;
}

/// 配对结果。
class PairOutcome {
  final String token;
  final String session;

  const PairOutcome({required this.token, required this.session});
}

/// 协议 v2 统一客户端：配对、索引、上传续传、下载续传、日志、断开。
///
/// 每个实例持有一个 [HttpClient]，单次任务内复用；
/// 但每个请求都显式 `Connection: close`，避免长连接下逐文件卡顿。
class PeerClient {
  final PeerDevice peer;
  final String token;
  final String session;
  final String deviceId;
  final String deviceName;
  final String role;
  final String form;
  final int localPort;

  final HttpClient _client;
  final Duration connectTimeout;

  PeerClient({
    required this.peer,
    required this.session,
    required this.deviceId,
    required this.deviceName,
    required this.role,
    required this.form,
    required this.localPort,
    this.token = '',
    this.connectTimeout = const Duration(seconds: 8),
  }) : _client = HttpClient()..idleTimeout = const Duration(seconds: 10);

  void close() {
    try {
      _client.close(force: true);
    } catch (_) {}
  }

  // ---- 配对 ----

  Future<PairOutcome> pair({String tokenToOffer = ''}) async {
    final req = await _open('POST', '/v2/pair');
    final body = jsonEncode({
      ...PeerDevice.describe(
        id: deviceId,
        name: deviceName,
        role: role,
        form: form,
        port: localPort,
        session: session,
      ),
      'app': AppConstants.appTag,
      'appVersion': AppConstants.currentVersion,
      'token': tokenToOffer,
    });
    final bytes = utf8.encode(body);
    req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close().timeout(AppConstants.controlTimeout);
    final map = await _readJson(res);
    if (res.statusCode == 200 && map['ok'] == true) {
      final issued = map['token'] as String? ?? '';
      if (issued.isEmpty) {
        throw const TransferException(500, 'BAD_RESPONSE', '对端未返回会话 token');
      }
      return PairOutcome(
        token: issued,
        session: map['session'] as String? ?? '',
      );
    }
    throw _errorFor(res.statusCode, map);
  }

  // ---- 索引 ----

  Future<List<FileEntry>> fetchIndex(String mappingName) async {
    final req = await _open('GET', '/v2/index', query: {'name': mappingName});
    final res = await req.close().timeout(AppConstants.indexTimeout);
    final map = await _readJson(res, timeout: AppConstants.indexTimeout);
    _ensureOk(res.statusCode, map);
    final list = (map['files'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.relativePath.isNotEmpty)
        .toList();
    return list;
  }

  // ---- 上传（PC → Android，分片续传）----

  /// 查询对端已接收偏移；对端未实现该端点时回退为 0。
  Future<int> resumeOffset(
    SyncMapping mapping,
    String relativePath,
    int size,
    int mtimeMs,
  ) async {
    final req = await _open('GET', '/v2/resume', query: {
      'name': mapping.name,
      'path': relativePath,
      'size': '$size',
      'mtime': '$mtimeMs',
    });
    final res = await req.close().timeout(AppConstants.controlTimeout);
    final map = await _readJson(res);
    if (res.statusCode == 404) return 0;
    _ensureOk(res.statusCode, map);
    final offset = (map['offset'] as num?)?.toInt() ?? 0;
    if (offset < 0 || offset > size) return 0;
    return offset;
  }

  /// 批量查询对端已接收偏移；对端未实现该端点时返回空表（由调用方逐文件回退）。
  Future<Map<String, int>> resumeOffsets(
    SyncMapping mapping,
    List<FileEntry> files,
  ) async {
    if (files.isEmpty) return const {};
    final req = await _open('POST', '/v2/resume/batch');
    final bytes = utf8.encode(jsonEncode({
      'name': mapping.name,
      'items': files
          .map((e) => {
                'p': e.relativePath,
                's': e.size,
                'm': e.mtimeMs,
              })
          .toList(),
    }));
    req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close().timeout(AppConstants.indexTimeout);
    final map = await _readJson(res, timeout: AppConstants.indexTimeout);
    if (res.statusCode == 404) return const {};
    _ensureOk(res.statusCode, map);
    final raw = map['offsets'];
    if (raw is! Map) return const {};
    final result = <String, int>{};
    raw.forEach((key, value) {
      if (key is String && value is num) result[key] = value.toInt();
    });
    return result;
  }

  Future<void> upload(
    SyncMapping mapping,
    String relativePath,
    File file, {
    required int mtimeMs,
    int start = 0,
  }) async {
    final size = await file.length();
    final req = await _open('POST', '/v2/upload', query: {
      'name': mapping.name,
      'path': relativePath,
      'size': '$size',
      'mtime': '$mtimeMs',
    });
    req.headers.set('X-Offset', '$start');
    req.contentLength = size - start;
    await req.addStream(file.openRead(start)).timeout(_fileTimeout(size));
    final res = await req.close().timeout(_fileTimeout(size));
    final map = await _readJson(res);
    _ensureOk(res.statusCode, map);
  }

  // ---- 下载（Android ← PC，HTTP Range 续传）----

  /// 把文件追加写入 [target]（通常为 `.part` 分片），返回已接收总字节数。
  Future<int> download(
    SyncMapping mapping,
    FileEntry entry,
    File target, {
    int start = 0,
  }) async {
    final req = await _open('GET', '/v2/file', query: {
      'name': mapping.name,
      'path': entry.relativePath,
    });
    if (start > 0) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
    }
    final res = await req.close().timeout(AppConstants.controlTimeout);
    if (res.statusCode != 200 && res.statusCode != 206) {
      final map = await _readJson(res);
      throw _errorFor(res.statusCode, map);
    }

    // 仅当对端确实按 Range 返回 206 时才追加；否则从 0 覆盖，避免重复写入。
    final append = start > 0 && res.statusCode == 206;
    final sink = target.openWrite(mode: append ? FileMode.append : FileMode.write);
    try {
      await sink.addStream(res.timeout(_fileTimeout(entry.size)));
      await sink.flush();
    } finally {
      await sink.close();
    }
    final received = await target.length();
    return received;
  }

  // ---- 日志与断开 ----

  Future<void> sendLog({
    required String name,
    required int fileCount,
    required int totalBytes,
    required List<String> files,
  }) async {
    final req = await _open('POST', '/v2/log');
    final bytes = utf8.encode(jsonEncode({
      'name': name,
      'count': fileCount,
      'bytes': totalBytes,
      'files': files,
    }));
    req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close().timeout(AppConstants.controlTimeout);
    final map = await _readJson(res);
    _ensureOk(res.statusCode, map);
  }

  Future<void> disconnect() async {
    final req = await _open('POST', '/v2/disconnect');
    req.contentLength = 0;
    final res = await req.close().timeout(AppConstants.controlTimeout);
    try {
      await res.drain<void>().timeout(AppConstants.controlTimeout);
    } catch (_) {}
  }

  // ---- 内部 ----

  Future<HttpClientRequest> _open(
    String method,
    String path, {
    Map<String, String>? query,
  }) async {
    final uri = Uri(
      scheme: 'http',
      host: peer.address,
      port: peer.port,
      path: path,
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
    final req = await _client.openUrl(method, uri).timeout(connectTimeout);
    req.headers.set(HttpHeaders.connectionHeader, 'close');
    req.headers.set('X-MySend-Proto', '${AppConstants.protoVersion}');
    if (token.isNotEmpty) {
      req.headers.set('X-MySend-Token', token);
    }
    return req;
  }

  Future<Map<String, dynamic>> _readJson(
    HttpResponse res, {
    Duration? timeout,
  }) async {
    try {
      final text = await res
          .transform(utf8.decoder)
          .join()
          .timeout(timeout ?? AppConstants.controlTimeout);
      return decodeJsonObject(text) ?? <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void _ensureOk(int status, Map<String, dynamic> map) {
    if (status == 200 && map['ok'] == true) return;
    throw _errorFor(status, map);
  }

  TransferException _errorFor(int status, Map<String, dynamic> map) {
    final code = map['code'] as String? ?? '';
    final raw = map['message'] as String? ?? '';
    if (code == 'BUSY') {
      return const TransferException(409, 'BUSY', '对端正在同步其他任务');
    }
    if (code == 'UNAUTHORIZED' || status == 401) {
      return const TransferException(401, 'UNAUTHORIZED', '会话已失效，请重新连接');
    }
    if (code == 'PROTO_MISMATCH' || status == 426) {
      return const TransferException(426, 'PROTO_MISMATCH', '两端协议版本不一致');
    }
    if (code == 'RANGE_INVALID' || status == 416) {
      return const TransferException(416, 'RANGE_INVALID', '续传位置不匹配');
    }
    if (code == 'FILE_NOT_FOUND') {
      return TransferException(404, code, raw.isEmpty ? '对端文件已不存在' : raw);
    }
    if (code == 'MAPPING_NOT_FOUND' || status == 404) {
      return TransferException(404, code, raw.isEmpty ? '对端不存在该映射' : raw);
    }
    if (code == 'NO_SPACE' || status == 507) {
      return const TransferException(507, 'NO_SPACE', '目标设备存储空间不足');
    }
    return TransferException(
      status,
      code,
      raw.isEmpty ? '请求失败（HTTP $status）' : raw,
    );
  }

  Duration _fileTimeout(int bytes) {
    var sec = (bytes / (1024 * 1024) * 2).ceil();
    if (sec < 60) sec = 60;
    final d = Duration(seconds: sec);
    return d > AppConstants.maxFileTimeout
        ? AppConstants.maxFileTimeout
        : d;
  }
}
