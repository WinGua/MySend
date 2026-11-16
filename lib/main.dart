import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'app_scope.dart';
import 'core/utils.dart';
import 'core/startup_report.dart';
import 'storage/app_storage.dart';
import 'services/windows_privileges.dart';

Future<void> main([List<String> args = const []]) async {
  WidgetsFlutterBinding.ensureInitialized();

  AppStorage.configure(args);
  scope = AppScope();
  final report = StartupReport.fromArguments(args);
  report?.mark('starting');
  runApp(MySendApp(
      restartAsAdministrator: isWindows ? _restartAsAdministrator : null,
      initialize: (showStage) async {
        void stage(String name) {
          showStage(name);
          if (report != null) {
            report.stage = name;
            report.mark('initializing');
          }
        }

        try {
          stage('正在启动 · 读取配置');
          await scope.config.load();
          stage('正在启动 · 初始化窗口');
          await _initWindow();
          await scope.startServices(onStage: stage);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            report?.mark('ready', firstFrame: true);
          });
        } catch (error) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            report?.mark('error',
                firstFrame: true, failure: error.runtimeType.toString());
          });
          rethrow;
        }
      }));
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

Future<bool> _restartAsAdministrator() async {
  if (scope.server?.busy ?? false) throw StateError('请先取消或等待当前同步完成');
  final path = await scope.storage.directoryForElevation();
  final started = await WindowsPrivileges.restartElevated(path);
  if (started) {
    await scope.stopServices();
    await windowManager.close();
  }
  return started;
}
