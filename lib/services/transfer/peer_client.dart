import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../models/device_info.dart';
import '../../models/file_entry.dart';
import '../../models/sync_mapping.dart';
import 'protocol.dart';
import 'buffered_stream.dart';
import 'local_transfer_server.dart';
import 'transfer_identity.dart';
import 'native_transport.dart';

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
/// 文件与会话控制分别复用 TLS 连接池，最多同时传输四个不同文件。
class PeerClient {
  final TransferIdentity identity;
  final PeerDevice peer;
  final String token;
  final String session;
  final String deviceId;
  final String deviceName;
  final String role;
  final String form;
  final int localPort;

  final HttpClient _client;
  final HttpClient _controlClient;
  final Duration connectTimeout;
  final void Function()? onClose;
  bool _closed = false;
  String? _task;
  Completer<void>? _syncDone;
  String? get activeTask => _task;
  bool get cancelled =>
      _leaseError is TransferException &&
      (_leaseError as TransferException).code == 'CANCELLED';
  Object? _leaseError;
  NativeTlsProxy? _nativeProxy;

  PeerClient({
    required this.identity,
    required this.peer,
    required this.session,
    required this.deviceId,
    required this.deviceName,
    required this.role,
    required this.form,
    required this.localPort,
    this.token = '',
    this.onClose,
    this.connectTimeout = const Duration(seconds: 8),
  })  : _client = _httpClient(peer, connectTimeout, 4),
        _controlClient = _httpClient(peer, connectTimeout, 1);

  static HttpClient _httpClient(
      PeerDevice peer, Duration timeout, int connections) {
    final client = (NativeTransport.instance == null
        ? HttpClient(context: SecurityContext(withTrustedRoots: false))
        : HttpClient())
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = connections
      ..connectionTimeout = timeout;
    client.findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (cert, host, port) =>
        host == peer.address &&
        port == peer.port &&
        sha256.convert(cert.der).toString() == peer.fingerprint &&
        DateTime.now().isAfter(cert.startValidity) &&
        DateTime.now().isBefore(cert.endValidity);
    return client;
  }

  /// 按设备 id 固定顺序占用两个服务端。任一步失败都释放已占用的槽位。
  Future<T> withSyncSession<T>(
      LocalTransferServer local, Future<T> Function() run) async {
    if (_task != null) throw const TransferException(409, 'BUSY', '已有同步任务正在进行');
    final task = newSessionId();
    _task = task;
    _syncDone = Completer<void>();
    var localHeld = false;
    var localEntered = false;
    Timer? heartbeat;
    Future<void>? renewing;
    void acquireLocal() {
      if (!local.sessions.acquire(deviceId, task)) {
        throw const TransferException(409, 'BUSY', '本机正在参与同步，请等待完成');
      }
      localHeld = true;
    }

    try {
      if (deviceId.compareTo(peer.id) < 0) {
        acquireLocal();
        await _sessionControl('acquire', task);
      } else {
        await _sessionControl('acquire', task);
        acquireLocal();
      }
      if (!local.sessions.enter(deviceId, task)) {
        throw const TransferException(409, 'SESSION_EXPIRED', '本机同步会话已失效');
      }
      localEntered = true;
      heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
        if (renewing != null) return;
        renewing = () async {
          try {
            if (!local.sessions.renew(deviceId, task)) {
              throw const TransferException(409, 'SESSION_EXPIRED', '同步会话已失效');
            }
            await _sessionControl('renew', task);
          } catch (error) {
            _leaseError ??= error;
            close();
          } finally {
            renewing = null;
          }
        }();
      });
      final result = await run();
      if (_leaseError != null) throw _leaseError!;
      return result;
    } finally {
      try {
        heartbeat?.cancel();
        await renewing;
        if (localEntered) local.sessions.leave();
        if (localHeld) local.sessions.release(deviceId, task);
        final release = _controlCleanup(task, 'release');
        // Local file I/O is already quiescent. A remote ACK must not hold the cancel UI.
        if (cancelled) {
          unawaited(release);
        } else {
          await release;
        }
      } finally {
        _task = null;
        if (!_syncDone!.isCompleted) _syncDone!.complete();
      }
    }
  }

  Future<void> _controlCleanup(String task, String operation) async {
    final cleanup = PeerClient(
        identity: identity,
        peer: peer,
        token: token,
        session: session,
        deviceId: deviceId,
        deviceName: deviceName,
        role: role,
        form: form,
        localPort: localPort);
    try {
      await cleanup._sessionControl(operation, task);
    } catch (_) {
      /* A disconnected peer reclaims its lease; file sockets are already closed. */
    } finally {
      cleanup.close();
    }
  }

  Future<void> requestCancellation(String task) =>
      _sessionControl('cancel', task);

  Future<void> cancel({bool notifyPeer = true}) async {
    final task = _task;
    _leaseError = const TransferException(499, 'CANCELLED', '同步已取消');
    if (task != null && notifyPeer) unawaited(_controlCleanup(task, 'cancel'));
    close();
    await _syncDone?.future;
  }

  Future<void> _sessionControl(String operation, String task) async {
    final req = await _open('POST', '/v2/sync/$operation',
        query: {'task': task}, control: true);
    req.contentLength = 0;
    final res =
        await _nativeAwait(req.close().timeout(AppConstants.controlTimeout));
    final map = await _readJson(res);
    if (res.statusCode == 404) {
      throw const TransferException(426, 'UPGRADE_REQUIRED', '请升级对端以支持安全同步会话');
    }
    _ensureOk(res.statusCode, map);
  }

  /// 同步生命周期只走控制连接；文件进度由对端自己的收发流统计。
  Future<void> sendSyncStatus(Map<String, dynamic> status) async {
    if (_task == null) throw StateError('尚未取得同步会话');
    final req = await _open('POST', '/v2/sync/status', control: true);
    final bytes = utf8.encode(jsonEncode(status));
    req.headers.contentType = ContentType.json;
    req.contentLength = bytes.length;
    req.add(bytes);
    final res =
        await _nativeAwait(req.close().timeout(AppConstants.controlTimeout));
    if (res.statusCode == 404) {
      await res.drain<void>();
      throw const TransferException(426, 'UPGRADE_REQUIRED', '请升级对端以支持双端同步进度');
    }
    _ensureOk(res.statusCode, await _readJson(res));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _client.close(force: true);
      _controlClient.close(force: true);
      _nativeProxy?.close();
    } catch (_) {}
    final done = _syncDone;
    if (done != null && !done.isCompleted) {
      unawaited(done.future.then((_) {
        onClose?.call();
      }));
    } else {
      onClose?.call();
    }
  }

  // ---- 配对 ----

  Future<PairOutcome> pair({String tokenToOffer = ''}) async {
    final req = await _open('POST', '/v2/pair');
    final body = jsonEncode({
      ...PeerDevice.describe(
        fingerprint: identity.fingerprint,
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
    final res =
        await _nativeAwait(req.close().timeout(AppConstants.controlTimeout));
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
    final res =
        await _nativeAwait(req.close().timeout(AppConstants.indexTimeout));
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
    final res =
        await _nativeAwait(req.close().timeout(AppConstants.controlTimeout));
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
    final res =
        await _nativeAwait(req.close().timeout(AppConstants.indexTimeout));
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
    void Function(int bytes)? onBytes,
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
    await _nativeAwait(req
        .addStream(readTransferFile(file, start: start, end: size).map((chunk) {
          onBytes?.call(chunk.length);
          return chunk;
        }))
        .timeout(_fileTimeout(size)));
    final res = await _nativeAwait(req.close().timeout(_fileTimeout(size)));
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
    void Function(int bytes)? onBytes,
  }) async {
    final req = await _open('GET', '/v2/file', query: {
      'name': mapping.name,
      'path': entry.relativePath,
    });
    if (start > 0) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
    }
    final res =
        await _nativeAwait(req.close().timeout(AppConstants.controlTimeout));
    if (res.statusCode != 200 && res.statusCode != 206) {
      final map = await _readJson(res);
      throw _errorFor(res.statusCode, map);
    }

    // 仅当对端确实按 Range 返回 206 时才追加；否则从 0 覆盖，避免重复写入。
    final append = start > 0 && res.statusCode == 206;
    final sink = target.openWrite(mode: append ? FileMode.append : FileMode.write);
    try {
      await sink.addStream(
          bufferedTransferStream(res.timeout(_fileTimeout(entry.size)))
              .map((chunk) {
        onBytes?.call(chunk.length);
        return chunk;
      }));
      await sink.flush();
    } finally {
      await sink.close();
    }
    final received = await target.length();
    return received;
  }

  // ---- 日志与断开 ----

  Future<void> sendLog(SyncLogReport report) async {
    final req = await _open('POST', '/v2/log');
    final bytes = utf8.encode(jsonEncode(report.toJson()));
    req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    req.contentLength = bytes.length;
    req.add(bytes);
    final res =
        await _nativeAwait(req.close().timeout(AppConstants.controlTimeout));
    final map = await _readJson(res);
    _ensureOk(res.statusCode, map);
  }

  Future<void> disconnect() async {
    final req = await _open('POST', '/v2/disconnect');
    req.contentLength = 0;
    final res =
        await _nativeAwait(req.close().timeout(AppConstants.controlTimeout));
    try {
      await res.drain<void>().timeout(AppConstants.controlTimeout);
    } catch (_) {}
  }

  // ---- 内部 ----

  Future<HttpClientRequest> _open(
    String method,
    String path, {
    Map<String, String>? query,
    bool control = false,
  }) async {
    if (_leaseError != null) throw _leaseError!;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(peer.fingerprint)) {
      throw const TransferException(426, 'UPGRADE_REQUIRED', '对端不支持加密连接，请升级对端');
    }
    final native = NativeTransport.instance;
    if (native != null) {
      _nativeProxy ??= native.client(peer.address, peer.port, peer.fingerprint);
    }
    final uri = Uri(
      scheme: _nativeProxy == null ? 'https' : 'http',
      host: _nativeProxy == null ? peer.address : '127.0.0.1',
      port: _nativeProxy?.port ?? peer.port,
      path: path,
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
    final transport = control ? _controlClient : _client;
    final req = await _nativeAwait(
        transport.openUrl(method, uri).timeout(connectTimeout));
    req.followRedirects = false;
    if (_task != null) req.headers.set('X-MySend-Sync', _task!);
    req.headers.set('X-MySend-Proto', '${AppConstants.protoVersion}');
    if (token.isNotEmpty) {
      req.headers.set('X-MySend-Token', token);
    }
    return req;
  }

  Future<T> _nativeAwait<T>(Future<T> operation) async {
    try {
      return await operation;
    } catch (error, stack) {
      if (cancelled) throw _leaseError!;
      final nativeError = _nativeProxy?.error ?? '';
      if (nativeError.toLowerCase().contains('certificate')) {
        Error.throwWithStackTrace(
            HandshakeException('对端证书身份或有效期校验失败：$nativeError'), stack);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _readJson(
    HttpClientResponse res, {
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
    if (code == 'ALREADY_EXISTS') {
      return TransferException(409, code, raw.isEmpty ? '目标文件已存在' : raw);
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
