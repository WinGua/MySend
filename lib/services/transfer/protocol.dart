import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/constants.dart';

/// 两端 HTTP 服务的公共能力（端口、会话 token 签发与撤销）。
abstract class TransferServer {
  bool get running;

  /// 实际监听端口（首选端口被占用时可能变化）。
  int get port;

  /// 是否有同步任务占用；占用期间拒绝新的配对请求。
  bool get busy;
  set busy(bool value);

  /// 为指定设备签发本机会话 token（同一设备只保留最新一个）。
  String issueTokenFor(String deviceId);

  /// 撤销本机签发给指定设备的全部 token。
  void revokeFor(String deviceId);
}

/// 服务端 token 表：token -> 设备 id。
class TokenStore {
  final Map<String, String> _tokens = {};
  final Random _random = Random.secure();

  bool contains(String token) => _tokens.containsKey(token);

  /// 签发新 token，并让该设备的旧 token 立即失效。
  String issueFor(String deviceId) {
    if (deviceId.isEmpty) return '';
    revokeFor(deviceId);
    final token = newToken();
    _tokens[token] = deviceId;
    return token;
  }

  /// 用对端会话 token 换取设备 id，并移除该 token。
  String? take(String token) {
    final deviceId = _tokens.remove(token);
    if (deviceId != null) revokeFor(deviceId);
    return deviceId;
  }

  void revokeFor(String deviceId) {
    _tokens.removeWhere((_, id) => id == deviceId);
  }

  void clear() => _tokens.clear();

  String newToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

/// 生成会话标识（每次应用/服务启动变化）。
String newSessionId() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 客户端是否携带了不匹配的协议版本头。
bool hasProtoMismatch(HttpRequest req) {
  final raw = req.headers.value('X-MySend-Proto');
  if (raw == null) return false;
  return int.tryParse(raw.trim()) != AppConstants.protoVersion;
}

/// 写出统一 JSON 响应，并显式关闭连接。
///
/// 较大的响应体（如目录索引）在对端声明支持 gzip 时压缩后发送，
/// Dart 的 HttpClient 默认会自动解压，客户端无需额外处理。
void writeJson(HttpRequest req, Map<String, dynamic> body, {int status = 200}) {
  final res = req.response;
  res.statusCode = status;
  res.headers.set(HttpHeaders.connectionHeader, 'close');
  res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
  final bytes = utf8.encode(jsonEncode(body));
  final acceptsGzip =
      (req.headers.value(HttpHeaders.acceptEncodingHeader) ?? '')
          .toLowerCase()
          .contains('gzip');
  if (acceptsGzip && bytes.length > 1024) {
    res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
    res.add(gzip.encode(bytes));
  } else {
    res.add(bytes);
  }
  res.close().ignore();
}

/// 写出统一错误响应：`{ok:false, code, message}`。
void writeError(
  HttpRequest req,
  int status,
  String code,
  String message,
) {
  writeJson(
    req,
    {'ok': false, 'code': code, 'message': message},
    status: status,
  );
}

/// 一次同步任务的日志报告，统一描述「本机发出 / 本机接收」。
///
/// 线上报文同时携带旧版的合计字段，保证旧版本对端仍能读取。
class SyncLogReport {
  final String mappingName;
  final String peerName;
  final DateTime time;

  final int sentCount;
  final int sentBytes;
  final List<String> sentFiles;

  final int receivedCount;
  final int receivedBytes;
  final List<String> receivedFiles;

  /// 报文是否携带方向信息；旧版对端只有合计字段。
  final bool directional;

  const SyncLogReport({
    required this.mappingName,
    required this.peerName,
    required this.time,
    this.sentCount = 0,
    this.sentBytes = 0,
    this.sentFiles = const [],
    this.receivedCount = 0,
    this.receivedBytes = 0,
    this.receivedFiles = const [],
    this.directional = true,
  });

  Map<String, dynamic> toJson() => {
        'name': mappingName,
        'peer': peerName,
        'time': time.millisecondsSinceEpoch,
        'sent': {'c': sentCount, 'b': sentBytes, 'f': sentFiles},
        'recv': {'c': receivedCount, 'b': receivedBytes, 'f': receivedFiles},
        // 旧版对端只认识合计字段。
        'count': sentCount + receivedCount,
        'bytes': sentBytes + receivedBytes,
        'files': [...sentFiles, ...receivedFiles],
      };

  /// 从对端日志报文解析。旧报文没有方向字段时按「本机接收」归档。
  factory SyncLogReport.fromJson(Map<String, dynamic> j) {
    final sent = _bucket(j['sent']);
    final recv = _bucket(j['recv']);
    final name = j['name'] as String? ?? '';
    final peer = j['peer'] as String? ?? '';
    final time = DateTime.fromMillisecondsSinceEpoch(
      (j['time'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
    );

    if (sent != null || recv != null) {
      return SyncLogReport(
        mappingName: name,
        peerName: peer,
        time: time,
        sentCount: sent?.count ?? 0,
        sentBytes: sent?.bytes ?? 0,
        sentFiles: sent?.files ?? const [],
        receivedCount: recv?.count ?? 0,
        receivedBytes: recv?.bytes ?? 0,
        receivedFiles: recv?.files ?? const [],
      );
    }

    final files = (j['files'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();
    return SyncLogReport(
      mappingName: name,
      peerName: peer,
      time: time,
      receivedCount: (j['count'] as num?)?.toInt() ?? files.length,
      receivedBytes: (j['bytes'] as num?)?.toInt() ?? 0,
      receivedFiles: files,
      directional: false,
    );
  }

  /// 站到对端视角：我发出的变成对方接收的，反之亦然。
  SyncLogReport mirrored() {
    if (!directional) return this;
    return SyncLogReport(
      mappingName: mappingName,
      peerName: peerName,
      time: time,
      sentCount: receivedCount,
      sentBytes: receivedBytes,
      sentFiles: receivedFiles,
      receivedCount: sentCount,
      receivedBytes: sentBytes,
      receivedFiles: sentFiles,
    );
  }

  static _LogBucket? _bucket(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final files = (map['f'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();
    return _LogBucket(
      count: (map['c'] as num?)?.toInt() ?? files.length,
      bytes: (map['b'] as num?)?.toInt() ?? 0,
      files: files,
    );
  }
}

class _LogBucket {
  final int count;
  final int bytes;
  final List<String> files;

  const _LogBucket({
    required this.count,
    required this.bytes,
    required this.files,
  });
}

/// 读取 JSON 对象请求体；超过上限或非法时返回 null。
Future<Map<String, dynamic>?> readJsonObject(
  HttpRequest req, {
  int maxBytes = 1024 * 1024,
}) async {
  if (req.contentLength > maxBytes) return null;
  try {
    final text = await utf8.decoder.bind(req).join();
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    // 请求体不是合法 JSON。
  }
  return null;
}
