import 'dart:io';

import '../core/utils.dart';

/// Windows 端：通过系统 `netsh wlan` 连接指定 WiFi 热点。
/// 使用「每用户 profile」（user=current），通常无需管理员权限。

/// 创建（或覆盖）指定 SSID 的每用户 WiFi profile，返回是否成功。
Future<bool> configureWifiProfile(String ssid, String passphrase) async {
  if (!isWindows) return false;
  try {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}mysend_$ssid.xml',
    );
    await file.writeAsString(_profileXml(ssid, passphrase));
    // 幂等：先删除可能存在的旧 profile（失败忽略）。
    await _netsh(['wlan', 'delete', 'profile', 'name="$ssid"']);
    return _netsh([
      'wlan',
      'add',
      'profile',
      'filename="${file.path}"',
      'user=current',
    ]);
  } catch (_) {
    return false;
  }
}

/// 连接指定 SSID 的 WiFi 网络，返回是否成功。
Future<bool> connectToWifi(String ssid) async {
  if (!isWindows) return false;
  return _netsh(['wlan', 'connect', 'name="$ssid"']);
}

Future<bool> _netsh(List<String> args) async {
  try {
    final r = await Process.run('netsh', args);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

String _profileXml(String ssid, String passphrase) =>
    '<?xml version="1.0"?>\n'
    '<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">\n'
    '  <name>$ssid</name>\n'
    '  <SSIDConfig><SSID><name>$ssid</name></SSID></SSIDConfig>\n'
    '  <connectionType>ESS</connectionType>\n'
    '  <connectionMode>manual</connectionMode>\n'
    '  <MSM><security>\n'
    '    <authEncryption><authentication>WPA2PSK</authentication>'
    '<encryption>AES</encryption><useOneX>false</useOneX></authEncryption>\n'
    '    <sharedKey><keyType>passPhrase</keyType><protected>false</protected>'
    '<keyMaterial>$passphrase</keyMaterial></sharedKey>\n'
    '  </security></MSM>\n'
    '</WLANProfile>\n';