// 云端打包辅助脚本：为 `flutter create` 生成的 MainActivity.kt 注入原生状态栏隐藏逻辑。
// 背景：OriginOS 上一切 Dart 侧 SystemUiMode 切换都会触发窗口重排、覆盖挖孔铺满（shortEdges）。
// 因此隐藏状态栏必须走原生 WindowInsetsControllerCompat，它只隐藏 insets、不改变窗口布局模式。
// 用法（在项目根目录）：dart tool/patch_android_kotlin.dart
import 'dart:io';

void main() {
  final kotlinRoot = Directory('android/app/src/main/kotlin');
  if (!kotlinRoot.existsSync()) {
    stderr.writeln('未找到 android/app/src/main/kotlin，请先运行 flutter create 生成脚手架');
    exit(1);
  }

  final candidates = kotlinRoot
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('MainActivity.kt'))
      .toList();

  if (candidates.isEmpty) {
    stderr.writeln('未找到 MainActivity.kt，跳过原生状态栏补丁');
    exit(1);
  }

  final file = candidates.first;
  final original = file.readAsStringSync();
  final packageMatch = RegExp(r'package\s+([\w.]+)').firstMatch(original);
  final packageName = packageMatch?.group(1) ?? 'com.example.music_sync';

  final content = '''
package $packageName

import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mysend/status_bar")
            .setMethodCallHandler { call, result ->
                if (call.method == "hideStatusBar") {
                    val controller = WindowCompat.getInsetsController(window, window.decorView)
                    controller.hide(WindowInsetsCompat.Type.statusBars())
                    controller.systemBarsBehavior =
                        WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
''';

  file.writeAsStringSync(content);
  stdout.writeln('MainActivity.kt 原生状态栏补丁完成（package: $packageName）');
}