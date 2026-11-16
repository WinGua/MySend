import 'package:flutter/services.dart';

/// Windows owns the UAC prompt; MySend never asks for or handles an admin password.
class WindowsPrivileges {
  static const MethodChannel _channel =
      MethodChannel('mysend/windows_privileges');
  static Future<bool> isElevated() async =>
      await _channel.invokeMethod<bool>('isElevated') ?? false;
  static Future<String> userDataDirectory() async {
    final path = await _channel.invokeMethod<String>('getUserDataDirectory');
    if (path == null || path.isEmpty) throw StateError('无法确定原用户的数据目录');
    return path;
  }

  static Future<bool> restartElevated(String dataDirectory) async =>
      await _channel.invokeMethod<bool>('restartElevated', dataDirectory) ??
      false;
}
