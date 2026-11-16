import 'dart:async';
import 'dart:io';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../models/device_info.dart';
import '../../models/remote_sync_state.dart';
import '../../models/sync_mapping.dart';
import '../../storage/config_repository.dart';
import '../local_index_service.dart';
import 'part_store.dart';
import 'buffered_stream.dart';
import 'protocol.dart';
import 'sync_session.dart';
import 'transfer_identity.dart';
import 'native_transport.dart';

/// 两端统一的 HTTP 服务（协议 v2）。
///
/// 电脑端与安卓端具备完全相同的端点，因此任意一端都能作为发送方或接收方：
/// - GET  /v2/hello
/// - POST /v2/pair
/// - GET  /v2/index      查询本机映射根索引
/// - GET  /v2/file       下载本机文件（支持 Range 续传）
/// - GET  /v2/resume     查询本机已接收偏移
/// - POST /v2/resume/batch 批量查询已接收偏移
/// - POST /v2/upload     分片续传上传（原子落盘）
/// - POST /v2/log        接收对端同步日志
/// - POST /v2/disconnect
class LocalTransferServer implements TransferServer {
  final TransferIdentity identity;
  late final SyncSession sessions;
  final RemoteSyncTracker remoteSync;
  Timer? _leaseSweep;
  final int preferredPort;
  final ConfigRepository config;

  /// 本机是否为电脑端：仅用于角色标识与选择映射的本地根目录。
  final bool isSender;
  final String session;

  /// 配对成功时回调，同时带回对端签发的 token（供本机反向调用）。
  final void Function(PeerDevice peer, String peerToken) onPeerPaired;

  /// 收到对端推送的同步日志。
  final Future<void> Function(SyncLogReport report) onSyncLog;

  /// 对端主动断开。
  final void Function(String deviceId) onDisconnect;
  final Future<bool> Function(String peerId, String task)? onCancelOutbound;

  /// 当前是否有同步任务占用（同一设备同一时刻只允许一个任务）。
  @override
  bool get busy => sessions.busy;

  /// 记录正在写入的目标：不同文件允许并发，同一文件只允许一个写入者。
  final Set<String> _uploads = {};

  HttpServer? _server;
  NativeTlsProxy? _nativeServer;
  final Set<Future<void>> _requests = {};
  final Map<HttpRequest, Future<void>> _dataRequests = {};
  final TokenStore _tokens = TokenStore();

  LocalTransferServer({
    RemoteSyncTracker? remoteSync,
    required this.identity,
    required this.preferredPort,
    required this.config,
    required this.isSender,
    required this.session,
    required this.onPeerPaired,
    required this.onSyncLog,
    required this.onDisconnect,
    this.onCancelOutbound,
  }) : remoteSync = remoteSync ?? RemoteSyncTracker() {
    sessions = SyncSession(onEnded: this.remoteSync.interrupted);
  }

  @override
  int get port => _nativeServer?.port ?? _server?.port ?? preferredPort;

  @override
  bool get running => _server != null;

  String get _role => isSender ? 'pc' : 'android';

  @override
  String issueTokenFor(String deviceId) => _tokens.issueFor(deviceId);

  @override
  void revokeFor(String deviceId) => _tokens.revokeFor(deviceId);

  Future<void> start() async {
    if (_server != null) return;
    final native = NativeTransport.instance;
    if (native != null) {
      // Plain HTTP is private to loopback. Only the native TLS listener is advertised.
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        _nativeServer = native.server(identity.certificate, identity.privateKey,
            _server!.port, preferredPort);
      } catch (_) {
        await _server!.close(force: true);
        _server = null;
        rethrow;
      }
    } else {
      try {
        _server = await HttpServer.bindSecure(
            InternetAddress.anyIPv4, preferredPort, identity.context);
      } on SocketException {
        _server = await HttpServer.bindSecure(
            InternetAddress.anyIPv4, 0, identity.context);
      }
    }
    _leaseSweep = Timer.periodic(const Duration(seconds: 5), (_) {
      sessions.busy;
    });
    _server!.listen((req) {
      final handling = _handle(req);
      _requests.add(handling);
      if (req.uri.path == '/v2/file' || req.uri.path == '/v2/upload') {
        _dataRequests[req] = handling;
      }
      handling.whenComplete(() {
        _requests.remove(handling);
        _dataRequests.remove(req);
      });
    });
  }

  Future<void> stop() async {
    _leaseSweep?.cancel();
    _leaseSweep = null;
    _nativeServer?.close();
    _nativeServer = null;
    try {
      await _server?.close(force: true);
    } catch (_) {}
    // 关闭套接字后，仍需等文件流与落盘处理退出，才能开放新服务的同步槽位。
    await Future.wait(_requests.toList());
    _server = null;
    _tokens.clear();
    sessions.clear();
  }

  Future<void> cancelTask(String task) async {
    final owner = sessions.owner;
    if (owner == null || !sessions.cancel(owner, task)) return;
    final targets = _dataRequests.entries
        .where((e) => e.key.headers.value('X-MySend-Sync') == task)
        .toList();
    for (final entry in targets) {
      final port = entry.key.connectionInfo?.remotePort;
      if (port != null) _nativeServer?.cancelConnection(port);
      entry.key.response.deadline = Duration.zero;
    }
    await Future.wait(targets.map((e) => e.value));
    remoteSync.interrupted(task, '同步已取消');
  }

  Future<void> _handle(HttpRequest req) async {
    var entered = false;
    try {
      final path = req.uri.path;
      if (path == '/v2/hello') {
        _hello(req);
        return;
      }
      if (path == '/v2/pair') {
        await _pair(req);
        return;
      }

      final token = req.headers.value('X-MySend-Token');
      if (token == null || !_tokens.contains(token)) {
        writeError(req, 401, 'UNAUTHORIZED', '缺少或错误的会话 token');
        return;
      }
      if (hasProtoMismatch(req)) {
        writeError(req, 426, 'PROTO_MISMATCH', '协议版本不一致');
        return;
      }

      final owner = _tokens.deviceFor(token)!;
      if (path == '/v2/sync/status') {
        final task = req.headers.value('X-MySend-Sync') ?? '';
        if (req.method != 'POST' || !sessions.enter(owner, task)) {
          writeError(req, 409, 'BUSY', '同步会话不存在');
          return;
        }
        entered = true;
        await _syncStatus(req, task);
        return;
      }
      if (path.startsWith('/v2/sync/')) {
        if (req.method != 'POST' || req.contentLength != 0) {
          writeError(req, 400, 'BAD_REQUEST', '会话控制需要空 POST 请求');
          return;
        }
        final task = req.uri.queryParameters['task'] ?? '';
        switch (path) {
          case '/v2/sync/cancel':
            if (sessions.matches(owner, task)) {
              await cancelTask(task);
            } else if (!(await onCancelOutbound?.call(owner, task) ?? false)) {
              writeError(req, 409, 'BUSY', '同步任务不存在');
              return;
            }
            writeJson(req, {'ok': true});
            return;
          case '/v2/sync/acquire':
            if (!sessions.acquire(owner, task)) {
              writeError(req, 409, 'BUSY', '已有同步任务正在进行');
            } else {
              writeJson(req, {'ok': true});
            }
            return;
          case '/v2/sync/renew':
            if (!sessions.renew(owner, task)) {
              writeError(req, 409, 'SESSION_EXPIRED', '同步会话已失效');
            } else {
              writeJson(req, {'ok': true});
            }
            return;
          case '/v2/sync/release':
            sessions.release(owner, task);
            writeJson(req, {'ok': true});
            return;
        }
      }
      if (const {
        '/v2/index',
        '/v2/file',
        '/v2/resume',
        '/v2/resume/batch',
        '/v2/upload'
      }.contains(path)) {
        final task = req.headers.value('X-MySend-Sync') ?? '';
        if (path == '/v2/index' && task.isEmpty && !busy) {
          // 对比允许在没有同步任务时独立执行。
        } else if (sessions.enter(owner, task)) {
          entered = true;
        } else {
          writeError(req, 409, 'BUSY', '请先取得两端同步会话，或等待当前同步完成');
          return;
        }
      }

      switch (path) {
        case '/v2/index':
          await _index(req);
          return;
        case '/v2/file':
          await _file(req);
          return;
        case '/v2/resume':
          await _resume(req);
          return;
        case '/v2/resume/batch':
          await _resumeBatch(req);
          return;
        case '/v2/upload':
          await _upload(req);
          return;
        case '/v2/log':
          await _log(req);
          return;
        case '/v2/disconnect':
          _disconnect(req, token);
          return;
        default:
          writeError(req, 404, 'NOT_FOUND', '未知端点');
          return;
      }
    } catch (e) {
      try {
        writeError(req, 500, 'IO_ERROR', '$e');
      } catch (_) {
        // 响应可能已发送，忽略二次写入异常。
      }
    } finally {
      if (entered) sessions.leave();
    }
  }

  Future<void> _syncStatus(HttpRequest req, String task) async {
    final body = await readJsonObject(req, maxBytes: 16 * 1024);
    if (body == null) {
      writeError(req, 400, 'BAD_REQUEST', '同步状态非法');
      return;
    }
    int? count(String key) {
      final v = body[key];
      return v is int && v >= 0 && v <= 1000000000 ? v : null;
    }

    switch (body['phase']) {
      case 'start':
        final name = body['name'];
        final peerName = body['peer'];
        if (name is! String ||
            _mapping(name) == null ||
            peerName is! String ||
            peerName.length > 128 ||
            count('total') == null) {
          writeError(req, 400, 'BAD_REQUEST', '同步计划非法');
          return;
        }
        remoteSync.begin(
            task: task,
            peerName: peerName,
            mappingName: name,
            total: count('total')!);
        break;
      case 'plan':
        if (!remoteSync.active(task) || count('total') == null) {
          writeError(req, 400, 'BAD_REQUEST', '同步任务或计划非法');
          return;
        }
        remoteSync.planned(task, count('total')!);
        break;
      case 'end':
        if (!remoteSync.active(task) ||
            count('sent') == null ||
            count('received') == null ||
            count('failed') == null ||
            (body['error'] != null &&
                (body['error'] is! String ||
                    (body['error'] as String).length > 2000))) {
          writeError(req, 400, 'BAD_REQUEST', '同步结果非法');
          return;
        }
        // 报文以发起端为视角，展示前交换发送与接收。
        remoteSync.finish(task,
            sentCount: count('received'),
            receivedCount: count('sent'),
            failed: count('failed')!,
            error: body['error'] as String?);
        break;
      default:
        writeError(req, 400, 'BAD_REQUEST', '同步阶段非法');
        return;
    }
    writeJson(req, {'ok': true});
  }

  void _hello(HttpRequest req) {
    if (hasProtoMismatch(req)) {
      writeError(req, 426, 'PROTO_MISMATCH', '协议版本不一致');
      return;
    }
    final cfg = config.config;
    writeJson(req, {
      'proto': AppConstants.protoVersion,
      'app': AppConstants.appTag,
      'version': AppConstants.currentVersion,
      'minPeer': AppConstants.minPeer,
      'protocol': 'https',
      'fingerprint': identity.fingerprint,
      'capabilities': ['sync-session'],
      'session': session,
      'device': {
        'id': cfg.deviceId,
        'name': cfg.deviceName,
        'role': _role,
      },
    });
  }

  Future<void> _pair(HttpRequest req) async {
    if (busy) {
      writeError(req, 409, 'BUSY', '正在同步中');
      return;
    }
    if (hasProtoMismatch(req)) {
      writeError(req, 426, 'PROTO_MISMATCH', '协议版本不一致');
      return;
    }
    final body = await readJsonObject(req);
    if (body == null) {
      writeError(req, 400, 'BAD_REQUEST', '请求体非法');
      return;
    }
    if ((body['proto'] as num?)?.toInt() != AppConstants.protoVersion) {
      writeError(req, 426, 'PROTO_MISMATCH', '协议版本不一致');
      return;
    }
    final peerRole = body['role'] as String? ?? '';
    // 只接受对端角色，避免同角色设备互连（电脑 ↔ 电脑、安卓 ↔ 安卓）。
    if (peerRole != 'pc' && peerRole != 'android') {
      writeError(req, 400, 'BAD_REQUEST', '角色不匹配');
      return;
    }
    if (peerRole == _role) {
      writeError(req, 400, 'BAD_REQUEST', '角色不匹配');
      return;
    }

    final info = req.connectionInfo;
    final original =
        info == null ? '' : _nativeServer?.origin(info.remotePort) ?? '';
    final remote =
        original.isNotEmpty ? original : info?.remoteAddress.address ?? '';
    final requester = PeerDevice.fromHello(body, remote);
    if (requester.id.isEmpty || requester.id == config.config.deviceId) {
      writeError(req, 400, 'BAD_REQUEST', '设备 id 缺失或与本机相同');
      return;
    }

    final known = config.config.trustedFingerprints[requester.id];
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(requester.fingerprint) ||
        (known != null && known != requester.fingerprint)) {
      writeError(req, 403, 'CERT_CHANGED', '对端证书身份缺失或已改变');
      return;
    }
    if (busy) {
      writeError(req, 409, 'BUSY', '正在同步中');
      return;
    }
    final peerToken = body['token'] as String? ?? '';
    final token = _tokens.issueFor(requester.id);
    onPeerPaired(requester.copyWith(connected: true), peerToken);

    final cfg = config.config;
    writeJson(req, {
      'ok': true,
      'token': token,
      'protocol': 'https',
      'fingerprint': identity.fingerprint,
      'capabilities': ['sync-session'],
      'session': session,
      'device': {
        'id': cfg.deviceId,
        'name': cfg.deviceName,
        'role': _role,
      },
    });
  }

  Future<void> _index(HttpRequest req) async {
    final mapping = _mapping(req.uri.queryParameters['name'] ?? '');
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射不存在');
      return;
    }
    final root = mapping.localRoot(isSender);
    if (root.isEmpty) {
      writeError(req, 409, 'MAPPING_NOT_CONFIGURED', '映射未配置本机目录');
      return;
    }
    final index = await LocalIndexService.scan(root);
    final files = index.values.map((e) => e.toJson()).toList()
      ..sort((a, b) => (a['p'] as String).compareTo(b['p'] as String));
    writeJson(req, {
      'ok': true,
      'name': mapping.name,
      'files': files,
    });
  }

  Future<void> _file(HttpRequest req) async {
    final mapping = _mapping(req.uri.queryParameters['name'] ?? '');
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射不存在');
      return;
    }
    final root = mapping.localRoot(isSender);
    if (root.isEmpty) {
      writeError(req, 409, 'MAPPING_NOT_CONFIGURED', '映射未配置本机目录');
      return;
    }
    final rel = req.uri.queryParameters['path'] ?? '';
    final target = LocalIndexService.safeFile(root, rel);
    if (target == null) {
      writeError(req, 400, 'PATH_INVALID', '路径非法');
      return;
    }
    if (!await target.exists()) {
      writeError(req, 404, 'FILE_NOT_FOUND', '文件不存在');
      return;
    }

    final total = await target.length();
    var start = 0;
    var status = 200;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d+)-$', caseSensitive: false)
          .firstMatch(range.trim());
      final parsed = int.tryParse(match?.group(1) ?? '');
      if (parsed == null || parsed < 0 || parsed >= total) {
        writeError(req, 416, 'RANGE_INVALID', 'Range 起点越界');
        return;
      }
      start = parsed;
      status = 206;
    }

    final res = req.response;
    res.statusCode = status;
    res.headers.contentType = ContentType('application', 'octet-stream');
    res.headers.set('Accept-Ranges', 'bytes');
    res.headers.contentLength = total - start;
    if (status == 206) {
      res.headers.set(
        'Content-Range',
        'bytes $start-${total - 1}/$total',
      );
    }
    final task = req.headers.value('X-MySend-Sync') ?? '';
    remoteSync.fileStarted(task, rel,
        sending: true, size: total, offset: start);
    var streamed = false;
    try {
      await res.addStream(
          readTransferFile(target, start: start, end: total).map((chunk) {
        remoteSync.transferred(task, chunk.length, path: rel);
        return chunk;
      }));
      streamed = true;
    } catch (_) {
      // 对端中断连接，忽略。
    }
    try {
      await res.close();
      if (streamed) {
        remoteSync.fileCompleted(task, total, sending: true, path: rel);
      }
    } catch (_) {}
  }

  Future<void> _resume(HttpRequest req) async {
    if (req.method != 'GET') {
      writeError(req, 400, 'BAD_REQUEST', '方法不支持');
      return;
    }
    final mapping = _mapping(req.uri.queryParameters['name'] ?? '');
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射不存在');
      return;
    }
    final rel = req.uri.queryParameters['path'] ?? '';
    final size = int.tryParse(req.uri.queryParameters['size'] ?? '');
    final mtime = int.tryParse(req.uri.queryParameters['mtime'] ?? '');
    if (!isValidRelPath(rel) || size == null || size < 0 || mtime == null) {
      writeError(req, 400, 'PATH_INVALID', '路径或大小非法');
      return;
    }
    final root = mapping.localRoot(isSender);
    if (root.isEmpty) {
      writeError(req, 409, 'MAPPING_NOT_CONFIGURED', '映射未配置本机目录');
      return;
    }
    final offset = await PartStore.currentOffset(
      root,
      rel,
      size,
      mtime,
    );
    writeJson(req, {'ok': true, 'offset': offset});
  }

  /// 批量查询续传偏移：请求体 `{name, items:[{p,s,m}]}`。
  Future<void> _resumeBatch(HttpRequest req) async {
    if (req.method != 'POST') {
      writeError(req, 400, 'BAD_REQUEST', '方法不支持');
      return;
    }
    final body = await readJsonObject(req);
    if (body == null) {
      writeError(req, 400, 'BAD_REQUEST', '请求体非法');
      return;
    }
    final mapping = _mapping(body['name'] as String? ?? '');
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射不存在');
      return;
    }
    final items = body['items'];
    if (items is! List || items.length > 5000) {
      writeError(req, 400, 'BAD_REQUEST', '文件列表非法');
      return;
    }

    final root = mapping.localRoot(isSender);
    if (root.isEmpty) {
      writeError(req, 409, 'MAPPING_NOT_CONFIGURED', '映射未配置本机目录');
      return;
    }
    final offsets = <String, int>{};
    for (final raw in items) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final rel = item['p'] as String? ?? '';
      final size = (item['s'] as num?)?.toInt();
      final mtime = (item['m'] as num?)?.toInt();
      if (!isValidRelPath(rel) || size == null || size < 0 || mtime == null) {
        continue;
      }
      offsets[rel] = await PartStore.currentOffset(root, rel, size, mtime);
    }
    writeJson(req, {'ok': true, 'offsets': offsets});
  }

  Future<void> _upload(HttpRequest req) async {
    if (req.method != 'POST') {
      writeError(req, 400, 'BAD_REQUEST', '方法不支持');
      return;
    }
    final mapping = _mapping(req.uri.queryParameters['name'] ?? '');
    if (mapping == null) {
      writeError(req, 404, 'MAPPING_NOT_FOUND', '映射不存在');
      return;
    }
    final rel = req.uri.queryParameters['path'] ?? '';
    final size = int.tryParse(req.uri.queryParameters['size'] ?? '');
    final mtime = int.tryParse(req.uri.queryParameters['mtime'] ?? '') ?? 0;
    if (!isValidRelPath(rel) || size == null || size < 0) {
      writeError(req, 400, 'PATH_INVALID', '路径或大小非法');
      return;
    }

    final root = mapping.localRoot(isSender);
    if (root.isEmpty) {
      writeError(req, 409, 'MAPPING_NOT_CONFIGURED', '映射未配置本机目录');
      return;
    }
    final dst = LocalIndexService.safeFile(root, rel);
    if (dst == null) {
      writeError(req, 400, 'PATH_INVALID', '路径非法');
      return;
    }
    final uploadKey = Platform.isWindows ? dst.path.toLowerCase() : dst.path;
    if (_uploads.contains(uploadKey) || _uploads.length >= 4) {
      writeError(req, 409, 'BUSY', '已有同步任务正在进行');
      return;
    }
    _uploads.add(uploadKey);

    try {
      // 双向同步只补新增：目标已存在时绝不覆盖。
      if (await dst.exists()) {
        writeError(req, 409, 'ALREADY_EXISTS', '目标文件已存在，已跳过');
        return;
      }
      final part = PartStore.partFile(root, rel);
      final currentOffset =
          await PartStore.currentOffset(root, rel, size, mtime);

      final offsetHeader = req.headers.value('X-Offset');
      final start =
          offsetHeader == null ? 0 : (int.tryParse(offsetHeader) ?? -1);
      if (start < 0 || start != currentOffset) {
        writeError(req, 416, 'RANGE_INVALID', '续传偏移不匹配');
        return;
      }
      if (req.contentLength >= 0 && req.contentLength != size - start) {
        writeError(req, 416, 'RANGE_INVALID', '请求体长度与剩余字节不一致');
        return;
      }

      await dst.parent.create(recursive: true);
      await part.parent.create(recursive: true);

      if (start == 0) {
        await PartStore.discard(root, rel);
      }
      await PartStore.writeMeta(
        root,
        rel,
        PartMeta(path: rel, size: size, mtime: mtime),
      );

      final task = req.headers.value('X-MySend-Sync') ?? '';
      remoteSync.fileStarted(task, rel,
          sending: false, size: size, offset: start);
      final sink = part.openWrite(mode: FileMode.append);
      var received = start;
      try {
        // 通过 addStream 维持背压，避免大文件写入时整段数据堆积在内存。
        await sink.addStream(bufferedTransferStream(req.timeout(
          const Duration(seconds: 45),
        )).map((chunk) {
          received += chunk.length;
          remoteSync.transferred(task, chunk.length, path: rel);
          if (received > size) throw const FormatException('数据超出预期大小');
          return chunk;
        }));
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (received != size) {
        // 数据不完整：保留分片，允许下次续传。
        writeError(req, 409, 'INCOMPLETE', '数据不完整，已保留分片');
        return;
      }

      // 完整性以「偏移 + 最终字节数」保证：数据不完整时不会被改名到目标路径。
      if (await dst.exists()) {
        writeError(req, 409, 'ALREADY_EXISTS', '目标文件已存在，已跳过');
        return;
      }
      await part.rename(dst.path);
      if (mtime > 0) {
        try {
          await dst.setLastModified(
            DateTime.fromMillisecondsSinceEpoch(mtime),
          );
        } catch (_) {}
      }
      await PartStore.discard(root, rel);
      remoteSync.fileCompleted(task, size, sending: false, path: rel);
      writeJson(req, {'ok': true, 'size': size});
    } catch (e) {
      if (_isNoSpace(e)) {
        writeError(req, 507, 'NO_SPACE', '目标磁盘空间不足');
      } else {
        writeError(req, 500, 'IO_ERROR', '$e');
      }
    } finally {
      _uploads.remove(uploadKey);
    }
  }

  Future<void> _log(HttpRequest req) async {
    // 大目录的文件名清单可能超过默认 1 MB，这里放宽到 8 MB。
    final body = await readJsonObject(req, maxBytes: 8 * 1024 * 1024);
    if (body == null) {
      writeError(req, 400, 'BAD_REQUEST', '请求体非法');
      return;
    }
    // 对端报文站在对端视角，本机保存前需要互换发送/接收。
    await onSyncLog(SyncLogReport.fromJson(body).mirrored());
    writeJson(req, {'ok': true});
  }

  void _disconnect(HttpRequest req, String token) {
    final id = _tokens.take(token);
    if (id == null || id.isEmpty) {
      writeError(req, 401, 'UNAUTHORIZED', '会话不存在');
      return;
    }
    onDisconnect(id);
    writeJson(req, {'ok': true});
  }

  SyncMapping? _mapping(String name) {
    for (final m in config.config.mappings) {
      if (m.name == name) return m;
    }
    return null;
  }

  bool _isNoSpace(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('no space left') ||
        msg.contains('enospc') ||
        msg.contains('errno = 28');
  }
}
