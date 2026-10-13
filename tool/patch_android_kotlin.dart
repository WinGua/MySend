// 云端打包辅助脚本：把 `flutter create` 生成的 MainActivity.kt 重写为原生全屏实现。
// 背景：OriginOS 上，Dart 侧一切 SystemChrome / SystemUiMode 切换都会触发窗口重排，
//       覆盖掉 AndroidManifest 里 windowLayoutInDisplayCutoutMode="shortEdges" 的挖孔铺满。
//       因此把「铺满挖孔 + 隐藏状态栏」全部下沉到原生，Dart 侧不再触碰任何系统 UI API。
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
    stderr.writeln('未找到 MainActivity.kt，跳过原生补丁');
    exit(1);
  }

  final file = candidates.first;
  final original = file.readAsStringSync();
  final packageMatch = RegExp(r'package\s+([\w.]+)').firstMatch(original);
  final packageName = packageMatch?.group(1) ?? 'com.example.music_sync';

  final content = '''
package $packageName

import android.graphics.Color
import android.os.Bundle
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyFullscreen()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applyFullscreen()
    }

    private fun applyFullscreen() {
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        // 铺满到状态栏/挖孔区域（edge-to-edge），配合 AndroidManifest 的 shortEdges。
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        // 必须先设 behavior 再 hide；下滑可暂时唤出系统栏，之后自动再次隐藏。
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.statusBars())
    }
}
''';

  file.writeAsStringSync(content);
  stdout.writeln('MainActivity.kt 原生全屏补丁完成（package: $packageName）');
}