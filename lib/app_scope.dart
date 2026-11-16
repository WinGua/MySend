import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'storage/app_storage.dart';

import 'core/utils.dart';
import 'models/device_info.dart';
import 'models/remote_sync_state.dart';
import 'services/discovery_service.dart';
import 'services/transfer/local_transfer_server.dart';
import 'services/transfer/part_store.dart';
import 'services/transfer/peer_client.dart';
import 'services/transfer/protocol.dart';
import 'services/transfer/transfer_identity.dart';
import 'storage/config_repository.dart';
import 'storage/sync_log_repository.dart';

/// 全局服务容器：封装配置、会话、发现、收发服务与同步日志。
class AppScope extends ChangeNotifier {
  final RemoteSyncTracker remoteSync = RemoteSyncTracker();
  final AppStorage storage;
  final ConfigRepository config;
  final SyncLogRepository syncLog;

  /// 本端会话标识，服务启动时生成；对端据此判断是否需要重新配对。
  String _session = newSessionId();

  String get session => _session;

  /// 对端签发给我们、用于调用对端的 token：deviceId -> token。
  final Map<String, String> _peerTokens = {};
  final Set<PeerClient> _clients = {};

  DiscoveryService? discovery;

  /// 两端统一的 HTTP 服务：同时具备发送与接收能力。
  LocalTransferServer? server;
  TransferIdentity? _identity;
  String? connectionError;

  AppScope({AppStorage? storage})
      : storage = storage ?? AppStorage.current,
        config = ConfigRepository(storage: storage ?? AppStorage.current),
        syncLog = SyncLogRepository(storage: storage ?? AppStorage.current) {
    syncLog.load();
  }

  String get role => isSender ? 'pc' : 'android';

  /// 当前本机 HTTP 服务。
  TransferServer? get transferServer => server;

  /// 当前 HTTP 服务实际监听端口（首选端口被占用时会由系统分配）。
  int get localPort => server?.port ?? config.config.transferPort;

  /// 为该对端创建协议客户端，自动携带会话 token。
  PeerClient clientFor(PeerDevice d) {
    late final PeerClient client;
    client = PeerClient(
      identity: _identity!,
      peer: d.copyWith(
          fingerprint:
              config.config.trustedFingerprints[d.id] ?? d.fingerprint),
      token: _peerTokens[d.id] ?? '',
      session: session,
      deviceId: config.config.deviceId,
      deviceName: config.config.deviceName,
      role: role,
      form: deviceForm,
      localPort: localPort,
      onClose: () => _clients.remove(client),
    );
    _clients.add(client);
    return client;
  }

  /// 主动连接：配对并交换会话 token。
  Future<bool> connect(PeerDevice d) async {
    connectionError = null;
    if (server?.busy ?? false) {
      connectionError = '本机正在参与同步，请等待完成后再连接';
      return false;
    }
    final client = clientFor(d);
    try {
      // 附带本机签发给对端的 token，让对端在配对后也能反向调用本机。
      final ownToken = server?.issueTokenFor(d.id) ?? '';
      final outcome = await client.pair(tokenToOffer: ownToken);
      _peerTokens[d.id] = outcome.token;
      config.config.trustedFingerprints[d.id] = client.peer.fingerprint;
      await config.save();
      final linked = d.copyWith(
        connected: true,
        session: outcome.session.isEmpty ? d.session : outcome.session,
      );
      discovery?.addScanned(linked, connected: true);
      notifyListeners();
      return true;
    } catch (e) {
      connectionError = e is HandshakeException
          ? '加密连接校验失败。请检查设备时间；若确认对端已重装，请先忘记设备再连接。'
          : '$e';
      server?.revokeFor(d.id);
      debugPrint('[MySend] 连接失败: $e');
      return false;
    } finally {
      client.close();
    }
  }

  /// 主动断开：通知对端并清理双方 token。
  Future<void> disconnect(PeerDevice d) async {
    final client = clientFor(d);
    try {
      await client.disconnect();
    } catch (_) {}
    client.close();
    _peerTokens.remove(d.id);
    transferServer?.revokeFor(d.id);
    discovery?.markDisconnected(d.id);
    notifyListeners();
  }

  /// 用户明确忘记设备后，下次连接重新信任其广播中的证书身份。
  Future<void> forgetPeer(String deviceId) async {
    config.config.trustedFingerprints.remove(deviceId);
    _peerTokens.remove(deviceId);
    transferServer?.revokeFor(deviceId);
    discovery?.markDisconnected(deviceId);
    await config.save();
    notifyListeners();
  }

  /// 依据当前配置（重新）启动所有后台服务。
  Future<void> startServices({ValueChanged<String>? onStage}) async {
    await stopServices();
    _session = newSessionId();
    final cfg = config.config;
    onStage?.call('正在启动 · 读取加密身份');
    final support = await storage.directory;
    _identity ??= await TransferIdentity.loadOrCreate(
      File('${support.path}/mysend_identity.json'),
    );

    // 先启动 HTTP 服务，确保发现报文携带的是实际监听端口。
    final local = LocalTransferServer(
      identity: _identity!,
      remoteSync: remoteSync,
      preferredPort: cfg.transferPort,
      config: config,
      isSender: isSender,
      session: session,
      onPeerPaired: _onPeerPaired,
      onSyncLog: _onSyncLog,
      onDisconnect: _onDisconnect,
      onCancelOutbound: _cancelFromPeer,
    );
    server = local;
    onStage?.call('正在启动 · 启动加密传输服务');
    try {
      await local.start();
    } catch (e) {
      debugPrint('[MySend] 同步服务启动失败: $e');
      rethrow;
    }

    // 两端都可能接收文件，启动时都清理各自映射根下的过期分片。
    onStage?.call('正在启动 · 清理过期分片');
    for (final m in cfg.mappings) {
      final root = m.localRoot(isSender);
      if (root.isNotEmpty) {
        await PartStore.cleanup(root);
      }
    }

    onStage?.call('正在启动 · 发现局域网设备');
    discovery = DiscoveryService(
      fingerprint: _identity!.fingerprint,
      deviceId: cfg.deviceId,
      deviceName: cfg.deviceName,
      isSender: isSender,
      form: deviceForm,
      transferPort: localPort,
      session: session,
      onPeerSessionChanged: _onPeerSessionChanged,
    );
    discovery!.addListener(notifyListeners);
    await discovery!.start();

    notifyListeners();
  }

  /// 配对成功：保存对端签发给本机的 token，并把设备标记为已连接。
  void _onPeerPaired(PeerDevice peer, String peerToken) {
    config.config.trustedFingerprints[peer.id] = peer.fingerprint;
    config.save();
    if (peerToken.isNotEmpty) {
      _peerTokens[peer.id] = peerToken;
    }
    discovery?.addScanned(peer, connected: true);
    notifyListeners();
  }

  /// 对端会话变化（服务重启）：双方旧 token 立即失效，需要重新连接。
  void _onPeerSessionChanged(String deviceId) {
    _peerTokens.remove(deviceId);
    transferServer?.revokeFor(deviceId);
    discovery?.markDisconnected(deviceId);
    notifyListeners();
  }

  /// 接收对端推送的同步日志并记录，实现同步双方各自留存日志。
  Future<void> _onSyncLog(SyncLogReport report) {
    return syncLog.add(
      name: report.mappingName,
      time: report.time,
      peerName: report.peerName,
      sentCount: report.sentCount,
      sentBytes: report.sentBytes,
      sentFiles: report.sentFiles,
      receivedCount: report.receivedCount,
      receivedBytes: report.receivedBytes,
      receivedFiles: report.receivedFiles,
    );
  }

  /// 对端主动断开：清理 token 并把设备标记为未连接。
  void _onDisconnect(String deviceId) {
    if (deviceId.isEmpty) return;
    debugPrint('[MySend] 对端断开: $deviceId');
    _peerTokens.remove(deviceId);
    transferServer?.revokeFor(deviceId);
    discovery?.markDisconnected(deviceId);
    notifyListeners();
  }

  Future<bool> _cancelFromPeer(String peerId, String task) async {
    final targets = _clients
        .where((c) => c.peer.id == peerId && c.activeTask == task)
        .toList();
    if (targets.isEmpty) return false;
    await Future.wait(targets.map((c) => c.cancel(notifyPeer: false)));
    return true;
  }

  Future<void> cancelCurrentSync() async {
    final targets = _clients.where((c) => c.activeTask != null).toList();
    final stops = targets.map((c) => c.cancel()).toList();
    final local = server;
    final task = local?.sessions.task;
    final owner = local?.sessions.owner;
    if (local != null && task != null && owner != config.config.deviceId) {
      final peers = discovery?.devices.where((p) => p.id == owner).toList() ??
          <PeerDevice>[];
      final peer = peers.isEmpty ? null : peers.first;
      if (peer != null) {
        final notify = clientFor(peer);
        unawaited(notify
            .requestCancellation(task)
            .catchError((Object _) {})
            .whenComplete(notify.close));
      }
      await local.cancelTask(task);
    }
    await Future.wait(stops);
  }

  Future<void> stopServices() async {
    await cancelCurrentSync();
    await Future.wait(_clients.toList().map((client) => client.cancel()));
    discovery?.removeListener(notifyListeners);
    await discovery?.stop();
    await server?.stop();
    discovery = null;
    server = null;
    _peerTokens.clear();
  }
}

/// 全局实例，在 `main()` 中初始化。
late AppScope scope;
