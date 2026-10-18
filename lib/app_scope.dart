import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core/utils.dart';
import 'models/device_info.dart';
import 'services/discovery_service.dart';
import 'services/transfer/receiver_server.dart';
import 'services/transfer/sender_server.dart';
import 'storage/config_repository.dart';
import 'storage/sync_log_repository.dart';

/// 全局服务容器：封装配置、发现、收发服务与同步日志，供各处单例访问。
class AppScope extends ChangeNotifier {
  final ConfigRepository config = ConfigRepository();
  final SyncLogRepository syncLog = SyncLogRepository();

  DiscoveryService? discovery;
  SenderServer? server; // 发送端（PC）HTTP 服务
  ReceiverServer? receiverServer; // 接收端（Android）HTTP 服务

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
        onSyncLog: _onSyncLog,
        onDisconnect: _onDisconnect,
      );
      await server!.start();
    } else {
      receiverServer = ReceiverServer(
        port: cfg.transferPort,
        mappingsProvider: () => config.config.mappings,
        onPairRequest: _onPairRequest,
        onSyncLog: _onSyncLog,
        onDisconnect: _onDisconnect,
      );
      await receiverServer!.start();
    }

    notifyListeners();
  }

  /// 收到对端配对请求：自动接受并标记对端已连接（已移除人工确认步骤）。
  Future<bool> _onPairRequest(PeerDevice requester) async {
    debugPrint('[MySend] 被动收到配对请求: ${requester.name} (${requester.address})');
    discovery?.addScanned(requester, connected: true);
    notifyListeners();
    return true;
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

  /// 对端主动断开：把该设备标记为未连接（保留在列表中，仅切换状态）。
  Future<void> _onDisconnect(String deviceId) async {
    if (deviceId.isEmpty) return;
    debugPrint('[MySend] 对端断开: $deviceId');
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
  }
}

/// 全局实例，在 `main()` 中初始化。
late AppScope scope;