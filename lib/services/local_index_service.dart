import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../core/utils.dart';
import '../models/file_entry.dart';

/// 本地文件索引扫描器。
///
/// 递归扫描一个根目录，产出 `相对路径 -> FileEntry` 映射；
/// 收录所有文件（跳过隐藏文件），并计算内容哈希用于「变更」比对。
class LocalIndexService {
  LocalIndexService._();

  /// 扫描 [root] 目录。
  /// [onProgress] 可选，用于报告累计扫描到的文件数量。
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
        final sha256 = await _sha256(entity);
        result[rel] = FileEntry(
          relativePath: rel,
          size: stat.size,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
          sha256: sha256,
        );
        count++;
        onProgress?.call(count);
      } catch (_) {
        // 单个文件读取/哈希失败不影响整体扫描。
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

  /// 流式计算文件 SHA-256，用于内容级变更比对。
  static Future<String> _sha256(File file) async {
    final digest = await crypto.sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
