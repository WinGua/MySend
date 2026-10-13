import 'package:file_picker/file_picker.dart';

/// 目录选择器。
///
/// - Windows：调用系统原生「选择文件夹」对话框，返回真实绝对路径。
/// - Android：调用系统 SAF 文件夹选择器，返回可写的真实路径
///   （写入依赖「所有文件访问」权限，见 permissions.dart）。
class FolderPicker {
  FolderPicker._();

  static Future<String?> pick() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath();
      if (result == null || result.isEmpty) return null;
      return result;
    } catch (_) {
      return null;
    }
  }
}