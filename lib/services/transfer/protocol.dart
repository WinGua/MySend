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
