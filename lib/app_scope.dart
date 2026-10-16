import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core/utils.dart';
import 'models/device_info.dart';
import 'services/discovery_service.dart';
import 'services/transfer/receiver_server.dart';
import 'services/transfer/sender_server.dart';
import 'storage/config_repository.dart';
import 'storage/sync_log_repository.dart';

/// 一次待确认的配对请求。
class PairRequest {
  final PeerDevice requester;
  final Completer<bool> completer;

  const PairRequest({required this.requester, required this.completer});
}

/// 全局服务容器：封装配置、发现、收发服务与同步日志，供各处单例访问。
class AppScope extends ChangeNotifier {
  final ConfigRepository config = ConfigRepository();
  final SyncLogRepository syncLog = SyncLogRepository();

  DiscoveryService? discovery;
  SenderServer? server; // 发送端（PC）HTTP 服务
  ReceiverServer? receiverServer; // 接收端（Android）HTTP 服务

  PairRequest? pairRequest; // 待确认的配对接入请求

  AppScope() {
    syncLog.load();
  }

  /// 描述自身设备的报文（用于配对请求）。
  Map<String, dynamic> selfDescribe() {
    final cfg = config.config;
    return PeerDevice.describe(
      id: cfg.deviceId,
      name: cfg.deviceName,
      platform: platformTag,
      form: deviceForm,
      isSender: isSender,
      port: cfg.transferPort,
    );
  }

  /// 依据当前配置（重新）启动所有后台服务。
  Future<void> startServices() async {
    await stopServices();
    final cfg = config.config;

    discovery = DiscoveryService(
      deviceId: cfg.deviceId,
      deviceName: cfg.deviceName,
      isSender: isSender,
      transferPort: cfg.transferPort,
    );
    discovery!.addListener(notifyListeners);
    await discovery!.start();

    if (isSender) {
      server = SenderServer(
        port: cfg.transferPort,
        mappingsProvider: () => config.config.mappings,
        onPairRequest: _onPairRequest,
      );
      await server!.start();
    } else {
      receiverServer = ReceiverServer(
        port: cfg.transferPort,
        mappingsProvider: () => config.config.mappings,
        onPairRequest: _onPairRequest,
      );
      await receiverServer!.start();
    }

    notifyListeners();
  }

  /// 收到对端配对请求：抛出待确认状态，等待 UI 弹窗结果。
  Future<bool> _onPairRequest(PeerDevice requester) {
    final completer = Completer<bool>();
    pairRequest = PairRequest(requester: requester, completer: completer);
    notifyListeners();
    return completer.future.timeout(const Duration(seconds: 60), onTimeout: () => false);
  }

  /// UI 弹窗给出结果后回调：完成配对请求，接受则把对端标记为已连接。
  void resolvePairRequest(bool accept) {
    final r = pairRequest;
    if (r == null) return;
    pairRequest = null;
    if (!r.completer.isCompleted) r.completer.complete(accept);
    if (accept) discovery?.addScanned(r.requester, connected: true);
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
  }
}

/// 全局实例，在 `main()` 中初始化。
late AppScope scope;