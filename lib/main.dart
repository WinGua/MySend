import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'app_scope.dart';
import 'core/utils.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  scope = AppScope();
  await scope.config.load();
  await _initWindow();
  await scope.startServices();

  runApp(const MySendApp());
}

/// Windows：无边框窗口 + Mica/Acrylic 磨砂玻璃，失败则优雅回退。
Future<void> _initWindow() async {
  if (!isWindows) return;

  try {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1100, 720),
      minimumSize: Size(820, 560),
      center: true,
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'MySend',
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  } catch (e) {
    debugPrint('window_manager 初始化失败: $e');
  }

  try {
    await acrylic.Window.initialize();
    await acrylic.Window.setEffect(
      effect: acrylic.WindowEffect.acrylic,
      color: const Color(0x80303030),
    );
  } catch (e) {
    debugPrint('磨砂玻璃效果不可用，回退为纯色: $e');
  }
}