import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// 生成一个 UUID（用作设备 id / 映射 id）。
String newUuid() => const Uuid().v4();

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

/// 获取本机第一个非回环 IPv4 地址（用于二维码配对与显示）。
Future<String?> localIpv4Address() async {
  try {
    final nics = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    for (final nic in nics) {
      for (final addr in nic.addresses) {
        final ip = addr.address;
        if (ip.isNotEmpty && !ip.startsWith('127.')) return ip;
      }
    }
  } catch (_) {}
  return null;
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

/// 判断目标 IP 是否与本机处于同一局域网（按 /24 网段比较，前三段一致即视为同网）。
/// 相比探测端口，此方式不受系统防火墙拦截 TCP 入站的影响。
Future<bool> inSameLan(String address) async {
  final local = await localIpv4Address();
  if (local == null || local.isEmpty) return false;
  final a = local.split('.');
  final b = address.split('.');
  if (a.length != 4 || b.length != 4) return false;
  return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}
