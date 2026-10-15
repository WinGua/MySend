import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/utils.dart';
import '../models/file_entry.dart';

/// 本地文件索引扫描器。
///
/// 递归扫描一个根目录，产出 `相对路径 -> FileEntry` 映射；
/// 收录所有文件（跳过隐藏文件），并计算内容哈希用于「变更」比对。
///
/// 性能策略（增量哈希）：
/// 首次扫描会为每个文件计算一次 SHA-256 并缓存到本地；之后每次扫描只需
/// 读取文件的「大小 + 修改时间」元数据（远快于读全文），仅当某个文件在本机
/// 的元数据相比上次发生变化时才重新计算其哈希。这样既保证内容级准确性，
/// 又避免每次对比都全量读盘哈希。
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

    final cache = await _loadCache(root);

    int count = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue; // 隐藏文件

      final rel = toRelativePath(root, entity.path);
      if (rel.isEmpty) continue;

      try {
        final stat = await entity.stat();
        final size = stat.size;
        final mtime = stat.modified.millisecondsSinceEpoch;

        // 本机元数据未变 → 复用上次缓存的哈希，跳过全文读取。
        final cached = cache[rel];
        String? sha256;
        if (cached != null &&
            cached.size == size &&
            cached.mtimeMs == mtime &&
            cached.sha256 != null) {
          sha256 = cached.sha256;
        } else {
          sha256 = await _sha256(entity);
        }

        result[rel] = FileEntry(
          relativePath: rel,
          size: size,
          mtimeMs: mtime,
          sha256: sha256,
        );
        cache[rel] = _CacheEntry(size: size, mtimeMs: mtime, sha256: sha256);
        count++;
        onProgress?.call(count);
      } catch (_) {
        // 单个文件读取/哈希失败不影响整体扫描。
      }
    }

    await _saveCache(root, cache);
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

  // ---- 哈希缓存（按根目录分别持久化） ----

  static Future<File> _cacheFile(String root) async {
    final dir = await getApplicationSupportDirectory();
    final key = crypto.sha256.convert(utf8.encode(root)).toString().substring(0, 16);
    return File(p.join(dir.path, 'index_cache_$key.json'));
  }

  static Future<Map<String, _CacheEntry>> _loadCache(String root) async {
    try {
      final f = await _cacheFile(root);
      if (!await f.exists()) return {};
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (j['root'] != root) return {}; // 根目录变更 → 缓存失效
      final entries = (j['entries'] as Map<String, dynamic>? ?? {});
      final map = <String, _CacheEntry>{};
      entries.forEach((k, v) {
        final m = Map<String, dynamic>.from(v as Map);
        map[k] = _CacheEntry(
          size: (m['size'] as num?)?.toInt() ?? 0,
          mtimeMs: (m['mtimeMs'] as num?)?.toInt() ?? 0,
          sha256: m['sha256'] as String?,
        );
      });
      return map;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveCache(String root, Map<String, _CacheEntry> cache) async {
    try {
      final f = await _cacheFile(root);
      await f.parent.create(recursive: true);
      final body = <String, dynamic>{
        'root': root,
        'entries': cache.map((k, v) => MapEntry(k, v.toJson())),
      };
      await f.writeAsString(jsonEncode(body), flush: true);
    } catch (_) {
      // 缓存写失败仅影响下次速度，不影响正确性。
    }
  }
}

/// 单文件哈希缓存条目（只在本机内部使用，不参与网络传输）。
class _CacheEntry {
  final int size;
  final int mtimeMs;
  final String? sha256;

  const _CacheEntry({required this.size, required this.mtimeMs, required this.sha256});

  Map<String, dynamic> toJson() => {
        'size': size,
        'mtimeMs': mtimeMs,
        if (sha256 != null) 'sha256': sha256,
      };
}