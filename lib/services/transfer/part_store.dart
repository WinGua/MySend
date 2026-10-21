import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/utils.dart';

/// 分片元数据，用于校验续传偏移与文件归属。
class PartMeta {
  final String path;
  final int size;
  final int mtime;

  const PartMeta({
    required this.path,
    required this.size,
    required this.mtime,
  });

  Map<String, dynamic> toJson() => {
        'p': path,
        'size': size,
        'mtime': mtime,
      };

  factory PartMeta.fromJson(Map<String, dynamic> j) => PartMeta(
        path: j['p'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        mtime: (j['mtime'] as num?)?.toInt() ?? 0,
      );
}

/// `.mysend-part` 分片管理：路径、元数据、续传偏移与过期清理。
///
/// 分片路径：`<目标根>/.mysend-part/<sha256(相对路径)>.part`
/// 元数据：同目录 `<...>.meta`
class PartStore {
  PartStore._();

  static String keyFor(String relativePath) =>
      sha256Hex(utf8.encode(relativePath));

  static File partFile(String root, String relativePath) => File(p.join(
        root,
        AppConstants.partDirName,
        '${keyFor(relativePath)}.part',
      ));

  static File metaFile(String root, String relativePath) => File(p.join(
        root,
        AppConstants.partDirName,
        '${keyFor(relativePath)}.meta',
      ));

  static Future<PartMeta?> readMeta(String root, String relativePath) async {
    try {
      final f = metaFile(root, relativePath);
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      return PartMeta.fromJson(Map<String, dynamic>.from(j));
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeMeta(
    String root,
    String relativePath,
    PartMeta meta,
  ) async {
    final f = metaFile(root, relativePath);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(meta.toJson()));
  }

  static Future<void> discard(String root, String relativePath) async {
    for (final f in [partFile(root, relativePath), metaFile(root, relativePath)]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 返回可续传的字节偏移。
  ///
  /// 分片缺失、元数据缺失、路径/大小/修改时间不一致时清理分片并返回 0，
  /// 避免把旧分片接到内容已变化的新文件后面。
  static Future<int> currentOffset(
    String root,
    String relativePath,
    int size,
    int mtime,
  ) async {
    final part = partFile(root, relativePath);
    final meta = await readMeta(root, relativePath);
    if (meta == null) {
      // 无元数据的孤立分片不可信，直接清理。
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
      return 0;
    }
    if (meta.path != relativePath || meta.size != size || meta.mtime != mtime) {
      await discard(root, relativePath);
      return 0;
    }
    if (!await part.exists()) return 0;
    final len = await part.length();
    if (len > size) {
      await discard(root, relativePath);
      return 0;
    }
    return len;
  }

  /// 服务启动时清理超过保留期的分片与元数据。
  static Future<void> cleanup(String root) async {
    final dir = Directory(p.join(root, AppConstants.partDirName));
    if (!await dir.exists()) return;
    final cutoff = DateTime.now()
        .subtract(AppConstants.partRetention)
        .millisecondsSinceEpoch;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.endsWith('.part') && !name.endsWith('.meta')) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.millisecondsSinceEpoch < cutoff) {
            await entity.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }
}
