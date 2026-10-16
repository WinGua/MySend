import 'package:flutter/services.dart';

import '../core/utils.dart';

/// Android 端「仅限本地」热点控制（通过 MethodChannel 桥接原生）。
class WifiHotspot {
  WifiHotspot._();

  static const MethodChannel _channel = MethodChannel('mysend/wifi');

  /// 开启一个仅本地热点（不共享上网、不消耗流量），返回是否成功。
  static Future<bool> start({
    required String ssid,
    required String passphrase,
  }) async {
    if (!isAndroid) return false;
    try {
      final r = await _channel.invokeMethod<bool>('startHotspot', {
        'ssid': ssid,
        'passphrase': passphrase,
      });
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 关闭当前热点（如有）。
  static Future<void> stop() async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod('stopHotspot');
    } catch (_) {}
  }
}