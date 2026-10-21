import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'constants.dart';

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

/// 校验协议相对路径：非空、相对、无 `..` / 空段 / `:`、不指向分片目录。
bool isValidRelPath(String relativePath) {
  if (relativePath.isEmpty) return false;
  if (relativePath.startsWith('/') || relativePath.startsWith('\\')) return false;
  if (relativePath.contains('\\')) return false;
  for (final part in relativePath.split('/')) {
    if (part.isEmpty || part == '.' || part == '..') return false;
    if (part.contains(':')) return false;
    if (part == AppConstants.partDirName) return false;
  }
  return true;
}

/// 计算字节数组的 SHA-256 小写十六进制摘要（用于生成分片文件名）。
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// 将 JSON 字符串安全解码为 Map；失败返回 null。
Map<String, dynamic>? decodeJsonObject(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  return null;
}


