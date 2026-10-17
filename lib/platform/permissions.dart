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

/// 请求后台保活所需的「通知」权限（Android 13+ 显示前台服务通知）。
Future<bool> ensureNotificationPermission() async {
  if (!isAndroid) return true;
  try {
    final status = await Permission.notification.request();
    return status.isGranted;
  } catch (_) {
    return false;
  }
}

/// 请求忽略电池优化（加入白名单），避免后台被 Doze 休眠。
Future<bool> requestBatteryOptimizationExemption() async {
  if (!isAndroid) return true;
  try {
    final status = await Permission.ignoreBatteryOptimizations.request();
    return status.isGranted;
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

/// 首次启动集中申请全部运行时权限（个人侧载场景）。
/// 顺序：先应用内弹窗（相机、通知），再跳系统设置（文件访问、电池优化）。
/// 已授权项重复 request 会直接返回 granted，不会重复打扰；
/// 后续各操作（扫码 / 同步）中若发现权限缺失，会按需再次引导申请。
Future<void> requestAllInitialPermissions() async {
  if (!isAndroid) return;
  // 相机（扫码添加设备）
  try {
    await Permission.camera.request();
  } catch (_) {}
  // 通知（后台保活前台服务常驻）
  await ensureNotificationPermission();
  // 所有文件访问（写入真实目录）
  await ensureFileAccess();
  // 忽略电池优化（后台保活白名单）
  await requestBatteryOptimizationExemption();
}
