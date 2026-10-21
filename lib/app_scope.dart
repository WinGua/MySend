import 'package:flutter/foundation.dart';

import 'core/utils.dart';
import 'models/device_info.dart';
import 'services/discovery_service.dart';
import 'services/transfer/part_store.dart';
import 'services/transfer/peer_client.dart';
import 'services/transfer/protocol.dart';
import 'services/transfer/receiver_server.dart';
import 'services/transfer/sender_server.dart';
import 'storage/config_repository.dart';
import 'storage/sync_log_repository.dart';

/// 全局服务容器：封装配置、会话、发现、收发服务与同步日志。
class AppScope extends ChangeNotifier {
  final ConfigRepository config = ConfigRepository();
  final SyncLogRepository syncLog = SyncLogRepository();

  /// 本端会话标识，服务启动时生成；对端据此判断是否需要重新配对。
  String _session = newSessionId();

  String get session => _session;

  /// 对端签发给我们、用于调用对端的 token：deviceId -> token。
  final Map<String, String> _peerTokens = {};

  DiscoveryService? discovery;
  SenderServer? server; // 发送端（PC）HTTP 服务
  ReceiverServer? receiverServer; // 接收端（Android）HTTP 服务

  AppScope() {
    syncLog.load();
  }

  String get role => isSender ? 'pc' : 'android';

  /// 当前角色对应的本机 HTTP 服务。
  TransferServer? get transferServer => isSender ? server : receiverServer;

  /// 当前 HTTP 服务实际监听端口（首选端口被占用时会由系统分配）。
  int get localPort {
    if (isSender) return server?.port ?? config.config.transferPort;
    return receiverServer?.port ?? config.config.transferPort;
  }

  /// 为该对端创建协议客户端，自动携带会话 token。
  PeerClient clientFor(PeerDevice d) => PeerClient(
        peer: d,
        token: _peerTokens[d.id] ?? '',
        session: session,
        deviceId: config.config.deviceId,
        deviceName: config.config.deviceName,
        role: role,
        form: deviceForm,
        localPort: localPort,
      );

  /// 主动连接：配对并交换会话 token。
  Future<bool> connect(PeerDevice d) async {
    final client = clientFor(d);
    try {
      // 附带本机签发给对端的 token，让对端在配对后也能反向调用本机。
      final ownToken = isSender
          ? (server?.issueTokenFor(d.id) ?? '')
          : (receiverServer?.issueTokenFor(d.id) ?? '');
      final outcome = await client.pair(tokenToOffer: ownToken);
      _peerTokens[d.id] = outcome.token;
      final linked = d.copyWith(
        connected: true,
        session: outcome.session.isEmpty ? d.session : outcome.session,
      );
      discovery?.addScanned(linked, connected: true);
      notifyListeners();
      return true;
    } catch (e) {
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

  /// 依据当前配置（重新）启动所有后台服务。
  Future<void> startServices() async {
    await stopServices();
    _session = newSessionId();
    final cfg = config.config;

    // 先启动 HTTP 服务，确保发现报文携带的是实际监听端口。
    if (isSender) {
      server = SenderServer(
        preferredPort: cfg.transferPort,
        config: config,
        session: session,
        onPeerPaired: _onPeerPaired,
        onSyncLog: _onSyncLog,
        onDisconnect: _onDisconnect,
      );
      try {
        await server!.start();
      } catch (e) {
        debugPrint('[MySend] 发送服务启动失败: $e');
      }
    } else {
      receiverServer = ReceiverServer(
        preferredPort: cfg.transferPort,
        config: config,
        deviceId: cfg.deviceId,
        deviceName: cfg.deviceName,
        session: session,
        onPeerPaired: _onPeerPaired,
        onSyncLog: _onSyncLog,
        onDisconnect: _onDisconnect,
      );
      try {
        await receiverServer!.start();
      } catch (e) {
        debugPrint('[MySend] 接收服务启动失败: $e');
      }
      for (final m in cfg.mappings) {
        if (m.destPath.isNotEmpty) {
          await PartStore.cleanup(m.destPath);
        }
      }
    }

    discovery = DiscoveryService(
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
  Future<void> _onSyncLog(String name, int count, int bytes, List<String> files) {
    return syncLog.add(
      name: name,
      fileCount: count,
      totalBytes: bytes,
      files: files,
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

  Future<void> stopServices() async {
    discovery?.removeListener(notifyListeners);
    await discovery?.stop();
    await server?.stop();
    await receiverServer?.stop();
    discovery = null;
    server = null;
    receiverServer = null;
    _peerTokens.clear();
  }
}

/// 全局实例，在 `main()` 中初始化。
late AppScope scope;
