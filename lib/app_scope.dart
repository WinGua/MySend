import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core/utils.dart';
import 'services/discovery_service.dart';
import 'services/local_index_service.dart';
import 'services/transfer/sender_server.dart';
import 'storage/config_repository.dart';

/// 全局服务容器：封装配置、发现、发送端服务，供各处单例访问。
class AppScope extends ChangeNotifier {
  final ConfigRepository config = ConfigRepository();
  DiscoveryService? discovery;
  SenderServer? server;

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
        deviceId: cfg.deviceId,
        deviceName: cfg.deviceName,
        port: cfg.transferPort,
        mappingsProvider: () => config.config.mappings,
      );
      await server!.start();
    }

    notifyListeners();

    // 启动即预热本机文件索引缓存，让首次「对比」也能即时出结果。
    warmAllIndexCaches();
  }

  Future<void> stopServices() async {
    discovery?.removeListener(notifyListeners);
    await discovery?.stop();
    await server?.stop();
    discovery = null;
    server = null;
  }

  /// 后台预热某个目录的文件哈希缓存（不阻塞 UI、不等待完成）。
  void warmIndexCache(String root) {
    if (root.trim().isEmpty) return;
    unawaited(_warmIndex(root));
  }

  Future<void> _warmIndex(String root) async {
    try {
      await LocalIndexService.scan(root);
    } catch (_) {
      // 预热的目录暂不可读（如安卓尚未授权）时静默忽略，不影响使用。
    }
  }

  /// 预热本机上所有映射涉及目录的缓存。
  void warmAllIndexCaches() {
    for (final m in config.config.mappings) {
      warmIndexCache(isSender ? m.sourcePath : m.destPath);
    }
  }
}

/// 全局实例，在 `main()` 中初始化。
late AppScope scope;