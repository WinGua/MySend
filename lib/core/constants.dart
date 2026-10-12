/// 全局常量与协议约定。
class AppConstants {
  AppConstants._();

  /// 局域网发现广播端口。
  static const int discoveryPort = 53317;

  /// HTTP 传输服务监听端口（PC 发送端）。
  static const int transferPort = 53318;

  /// 配置文件文件名。
  static const String configFileName = 'music_sync_config.json';

  /// 当前协议版本，用于发现报文校验。
  static const String protocolTag = 'music_sync/1';

  /// 支持同步的音频扩展名。
  static const List<String> audioExtensions = [
    '.mp3', '.flac', '.m4a', '.wav', '.aac', '.ogg',
    '.opus', '.wma', '.ape', '.alac', '.aiff', '.dsf',
  ];

  /// 判断文件是否为音频文件。
  static bool isAudio(String fileName) {
    final lower = fileName.toLowerCase();
    return audioExtensions.any(lower.endsWith);
  }
}
