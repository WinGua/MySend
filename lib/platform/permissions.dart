import 'package:permission_handler/permission_handler.dart';

import '../core/utils.dart';

/// 请求 Android 端所需的「所有文件访问」权限（个人侧载场景，
/// 直接读写 `/storage/emulated/0/...` 绝对路径）。PC 端恒为 true。
Future<bool> ensureFileAccess() async {
  if (!isAndroid) return true;
  try {
    final status = await Permission.manageExternalStorage.status;
    if (status.isGranted) return true;
    final requested = await Permission.manageExternalStorage.request();
    if (requested.isGranted) return true;
    // 旧版本 Android（<=9）回退到存储权限。
    final legacy = await Permission.storage.request();
    return legacy.isGranted;
  } catch (_) {
    return false;
  }
}

/// 打开系统设置中的「所有文件访问」页面（当权限被拒绝时引导用户）。
Future<void> openManageStorageSettings() async {
  if (!isAndroid) return;
  try {
    await openAppSettings();
  } catch (_) {}
}
