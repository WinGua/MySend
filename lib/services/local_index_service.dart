import 'dart:io';
import 'package:path/path.dart' as p;

import '../core/utils.dart';
import '../models/file_entry.dart';

/// 本地文件索引扫描器。
///
/// 递归扫描一个根目录，产出 `相对路径 -> FileEntry` 映射（跳过隐藏/系统文件）。
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
    // 限制并发 stat 数量：既避免串行扫描大目录过慢，也避免一次打开过多句柄。
    final pending = <Future<void>>[];
    const maxInflight = 8;

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final rel = toRelativePath(root, entity.path);
      if (rel.isEmpty) continue;
      if (_isIgnoredPath(rel)) continue; // 跳过隐藏/系统文件及隐藏目录内容

      pending.add(_addEntry(entity, rel, result, () {
        count++;
        onProgress?.call(count);
      }));
      if (pending.length >= maxInflight) {
        await pending.removeAt(0);
      }
    }
    await Future.wait(pending);

    return result;
  }

  /// 读取单个文件元数据并写入索引；失败时忽略，不影响整体扫描。
  static Future<void> _addEntry(
    File file,
    String rel,
    Map<String, FileEntry> result,
    void Function() onCounted,
  ) async {
    try {
      final stat = await file.stat();
      result[rel] = FileEntry(
        relativePath: rel,
        size: stat.size,
        mtimeMs: stat.modified.millisecondsSinceEpoch,
      );
      onCounted();
    } catch (_) {
      // 单个文件读取失败不影响整体扫描。
    }
  }

  /// 判断相对路径是否应被忽略：跳过不应同步的系统/临时/缓存文件与隐藏目录。
  /// 覆盖：任一路径段以 `.` 开头的隐藏文件/目录、Windows 资源管理器系统文件
  /// （desktop.ini / thumbs.db / ehthumbs.db）、以及 Office 等程序的临时锁文件
  /// （`~$` 开头）。
  static bool _isIgnoredPath(String relPath) {
    for (final part in relPath.split('/')) {
      if (part.isEmpty) continue;
      if (part.startsWith('.')) return true;
      if (part.startsWith('~\u0024')) return true;
      final lower = part.toLowerCase();
      if (lower == 'desktop.ini' ||
          lower == 'thumbs.db' ||
          lower == 'ehthumbs.db') {
        return true;
      }
    }
    return false;
  }

  /// 校验安全路径并解析为绝对路径；非法则返回 null。
  static File? safeFile(String root, String relativePath) {
    if (!isValidRelPath(relativePath)) {
      return null;
    }
    if (!isSafeWithin(root, relativePath)) {
      return null;
    }
    return File(p.join(root, relativePath.replaceAll('/', Platform.pathSeparator)));
  }
}