import 'core/utils.dart';
import 'services/discovery_service.dart';
import 'services/transfer/sender_server.dart';
import 'storage/config_repository.dart';

/// 全局服务容器：封装配置、发现、发送端服务，供各处单例访问。
class AppScope {
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
  }

  Future<void> stopServices() async {
    await discovery?.stop();
    await server?.stop();
    discovery = null;
    server = null;
  }
}

/// 全局实例，在 `main()` 中初始化。
late AppScope scope;
