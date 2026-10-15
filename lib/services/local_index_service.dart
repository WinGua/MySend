import 'dart:io';
import 'package:path/path.dart' as p;

import '../core/utils.dart';
import '../models/file_entry.dart';

/// 本地文件索引扫描器。
///
/// 递归扫描一个根目录，产出 `相对路径 -> FileEntry` 映射（跳过隐藏文件）。
/// 仅记录「相对路径、大小、修改时间」，用于判断接收端是否已存在同名文件，
/// 即「只同步新增文件」。
class LocalIndexService {
  LocalIndexService._();

  static Future<Map<String, FileEntry>> scan(
    String root, {
    void Function(int count)? onProgress,
  }) async {
    final result = <String, FileEntry>{};
    final dir = Directory(root);
    if (root.trim().isEmpty || !await dir.exists()) {
      return result;
    }

    int count = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue; // 隐藏文件

      final rel = toRelativePath(root, entity.path);
      if (rel.isEmpty) continue;

      try {
        final stat = await entity.stat();
        result[rel] = FileEntry(
          relativePath: rel,
          size: stat.size,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
        );
        count++;
        onProgress?.call(count);
      } catch (_) {
        // 单个文件读取失败不影响整体扫描。
      }
    }

    return result;
  }

  /// 校验安全路径并解析为绝对路径；非法则返回 null。
  static File? safeFile(String root, String relativePath) {
    if (!isSafeWithin(root, relativePath)) {
      return null;
    }
    return File(p.join(root, relativePath.replaceAll('/', Platform.pathSeparator)));
  }
}