import 'package:file_picker/file_picker.dart';

import '../core/utils.dart';

/// 目录选择器。
///
/// - Windows：调用系统原生「选择文件夹」对话框，返回真实绝对路径。
/// - Android：SAF 目录选择无法直接映射为真实路径，故由 UI 提供路径输入框，
///   本方法在 Android 上返回 null 并交由调用方引导用户手动填写。
class FolderPicker {
  FolderPicker._();

  static Future<String?> pick() async {
    if (!isWindows) return null;
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null || result.isEmpty) return null;
    return result;
  }
}
