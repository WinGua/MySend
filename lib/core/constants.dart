/// 全局常量与协议约定。
class AppConstants {
  AppConstants._();

  /// 局域网发现广播端口。
  static const int discoveryPort = 53317;

  /// HTTP 传输服务监听端口（PC 发送端）。
  static const int transferPort = 53318;

  /// 配置文件文件名。
  static const String configFileName = 'mysend_config.json';

  /// 当前协议版本，用于发现报文校验。
  static const String protocolTag = 'mysend/1';

  /// 当前应用版本（与 pubspec.yaml 的 version 保持一致，用于检查更新）。
  static const String currentVersion = '1.0.0';

  /// 项目仓库地址。
  static const String repoUrl = 'https://github.com/WinGua/MySend';

  /// GitHub Releases 页面地址（跳转下载）。
  static const String releasesUrl = 'https://github.com/WinGua/MySend/releases';

  /// GitHub Releases 最新版本查询接口。
  static const String releasesApiUrl =
      'https://api.github.com/repos/WinGua/MySend/releases/latest';
}
