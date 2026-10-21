/// 全局常量与协议约定（传输协议 v2）。
class AppConstants {
  AppConstants._();

  /// 局域网 UDP 发现广播端口。
  static const int discoveryPort = 53317;

  /// HTTP 传输服务默认监听端口。
  static const int transferPort = 53318;

  /// 传输协议版本。
  static const int protoVersion = 2;

  /// 本端应用标识（写入 hello / pair 报文）。
  static const String appTag = 'mysend';

  /// 当前应用版本（与 pubspec.yaml 的 version 保持一致，用于检查更新）。
  static const String currentVersion = '1.0.0';

  /// 可接受的最低对端版本。
  static const int minPeer = 1;

  /// 分片目录名（位于每个映射根目录下）。
  static const String partDirName = '.mysend-part';

  /// 配置文件文件名。
  static const String configFileName = 'mysend_config.json';

  /// 同步日志文件名。
  static const String logFileName = 'mysend_logs.json';

  /// 设备过期时间：超过该时长未收到广播视为离线。
  static const Duration peerTimeout = Duration(seconds: 12);

  /// 控制请求（索引 / 续传 / 配对 / 日志）超时。
  static const Duration controlTimeout = Duration(seconds: 10);

  /// 目录索引请求超时（大目录扫描可能较慢）。
  static const Duration indexTimeout = Duration(seconds: 60);

  /// 文件传输超时上限。
  static const Duration maxFileTimeout = Duration(minutes: 10);

  /// 分片保留时长。
  static const Duration partRetention = Duration(days: 7);

  /// 项目仓库地址。
  static const String repoUrl = 'https://github.com/WinGua/MySend';

  /// GitHub Releases 页面地址（跳转下载）。
  static const String releasesUrl = 'https://github.com/WinGua/MySend/releases';

  /// GitHub Releases 最新版本查询接口。
  static const String releasesApiUrl =
      'https://api.github.com/repos/WinGua/MySend/releases/latest';
}
