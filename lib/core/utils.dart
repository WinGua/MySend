import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// 生成一个 UUID（用作设备 id / 映射 id）。
String newUuid() => const Uuid().v4();

/// 延迟释放控制器，等待弹窗退场动画结束后再销毁。
void disposeControllerLater(TextEditingController controller) {
  Timer(const Duration(milliseconds: 400), controller.dispose);
}

/// 将字节数格式化为便于阅读的字符串。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 是否运行在 Windows 桌面端。
bool get isWindows => !kIsWeb && Platform.isWindows;

/// 是否运行在 Android 端。
bool get isAndroid => !kIsWeb && Platform.isAndroid;

/// 当前设备角色：PC 为发送端，Android 为接收端。
bool get isSender => isWindows;

/// 平台标识字符串，写入发现报文。
String get platformTag => isWindows ? 'windows' : (isAndroid ? 'android' : 'other');

/// 设备形态：桌面 / 平板 / 手机（平板按最短边 ≥ 600dp 判定）。
String get deviceForm {
  if (isWindows) return 'desktop';
  if (!isAndroid) return 'other';
  try {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    return size.shortestSide >= 600 ? 'tablet' : 'phone';
  } catch (_) {
    return 'phone';
  }
}

/// 计算文件相对根目录的相对路径（统一使用 `/` 分隔，跨平台一致）。
String toRelativePath(String root, String filePath) {
  final rel = p.relative(filePath, from: root).replaceAll('\\', '/');
  return rel;
}

/// 校验子路径是否安全地落在 [root] 目录内（防路径穿越）。
bool isSafeWithin(String root, String relativePath) {
  final normalizedRoot = p.normalize(root).replaceAll('\\', '/');
  final normalizedChild = p.normalize(p.join(root, relativePath)).replaceAll('\\', '/');
  final prefix = normalizedRoot.endsWith('/') ? normalizedRoot : '$normalizedRoot/';
  return normalizedChild == normalizedRoot || normalizedChild.startsWith(prefix);
}


