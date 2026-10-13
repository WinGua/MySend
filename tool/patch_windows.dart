// 云端打包辅助脚本：把 `flutter create` 生成的 Windows 工程里的可执行文件名
// 与窗口标题、文件元数据从 music_sync 改为 MySend。
// 用法（在项目根目录）：dart tool/patch_windows.dart
import 'dart:io';

void main() {
  // 关键：可执行文件名（music_sync.exe -> MySend.exe）
  _patch('windows/CMakeLists.txt', 'set(BINARY_NAME "music_sync")', 'set(BINARY_NAME "MySend")');
  // 原生窗口标题（Flutter 启动前瞬间显示，随后被 window_manager 覆盖）
  _patch('windows/runner/main.cpp', 'L"music_sync"', 'L"MySend"');
  // 文件属性/任务管理器里的产品描述与原始文件名（先替换带 .exe 的，避免遗漏）
  _patch('windows/runner/Runner.rc', '"music_sync.exe"', '"MySend.exe"');
  _patch('windows/runner/Runner.rc', '"music_sync"', '"MySend"');
  stdout.writeln('Windows 二进制品名补丁完成');
}

void _patch(String path, String from, String to) {
  final f = File(path);
  if (!f.existsSync()) {
    stderr.writeln('跳过（未找到 $path）');
    return;
  }
  var c = f.readAsStringSync();
  if (!c.contains(from)) {
    stderr.writeln('跳过（$path 中未找到 "$from"）');
    return;
  }
  c = c.replaceAll(from, to);
  f.writeAsStringSync(c);
  stdout.writeln('$path: $from -> $to');
}