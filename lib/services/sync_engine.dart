import 'dart:io';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/utils.dart';
import '../models/file_entry.dart';
import '../models/sync_mapping.dart';
import '../models/sync_plan.dart';
import 'local_index_service.dart';
import 'transfer/part_store.dart';
import 'transfer/peer_client.dart';

/// 同步引擎：计算差异、执行单向传输（发送端 → 接收端）。
///
/// 规则：
/// - 「新增」= 发送端索引中存在、接收端不存在的相对路径 → 待传。
/// - 只同步新增文件，不比对内容、不处理删除。
/// - 传输走协议 v2：先落 `.mysend-part` 分片，完成后原子改名。
class SyncEngine {
  SyncEngine._();

  static SyncPlan computePlan({
    required SyncMapping mapping,
    required Map<String, FileEntry> source,
    required Map<String, FileEntry> dest,
  }) {
    final newOnly = <FileEntry>[];

    for (final e in source.values) {
      if (!dest.containsKey(e.relativePath)) {
        newOnly.add(e);
      }
    }

    final toSend = <FileEntry>[...newOnly];
    toSend.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    return SyncPlan(
      mappingId: mapping.id,
      mappingName: mapping.name,
      toSend: toSend,
      newOnly: newOnly,
    );
  }

  /// 依次从对端拉取 [files] 写入本机 [mapping.destPath]。
  ///
  /// 单个文件失败不中断任务，返回失败数量。调用方负责关闭 [client]。
  static Future<int> run({
    required SyncMapping mapping,
    required PeerClient client,
    required List<FileEntry> files,
    required void Function(int done, int total, FileEntry current) onProgress,
    void Function(FileEntry entry, Object error)? onFailure,
  }) async {
    final total = files.length;
    var failed = 0;
    for (var i = 0; i < total; i++) {
      final e = files[i];
      try {
        await _pullOne(mapping, client, e);
        onProgress(i + 1 - failed, total, e);
      } catch (err) {
        failed++;
        onFailure?.call(e, err);
      }
    }
    return failed;
  }

  /// 依次把 [files] 推送到对端（供 PC 发起同步时使用）。
  ///
  /// 单个文件失败不中断任务，返回失败数量。调用方负责关闭 [client]。
  static Future<int> push({
    required SyncMapping mapping,
    required PeerClient client,
    required List<FileEntry> files,
    required void Function(int done, int total, FileEntry current) onProgress,
    void Function(FileEntry entry, Object error)? onFailure,
  }) async {
    final total = files.length;
    // 先批量查询续传偏移，正常情况整批文件只需一次请求。
    var offsets = const <String, int>{};
    try {
      final merged = <String, int>{};
      const chunkSize = 2000;
      for (var i = 0; i < files.length; i += chunkSize) {
        final end = (i + chunkSize < files.length) ? i + chunkSize : files.length;
        merged.addAll(
          await client.resumeOffsets(mapping, files.sublist(i, end)),
        );
      }
      offsets = merged;
    } catch (_) {
      // 对端不支持批量查询时回退为逐文件查询。
    }

    var failed = 0;
    for (var i = 0; i < total; i++) {
      final e = files[i];
      final srcFile = p.join(
        mapping.sourcePath,
        e.relativePath.replaceAll('/', Platform.pathSeparator),
      );
      try {
        final start = offsets[e.relativePath] ??
            await client
                .resumeOffset(mapping, e.relativePath, e.size, e.mtimeMs)
                .timeout(AppConstants.controlTimeout);
        try {
          await client.upload(
            mapping,
            e.relativePath,
            File(srcFile),
            mtimeMs: e.mtimeMs,
            start: start,
          );
        } on TransferException catch (err) {
          // 分片在批量查询后发生变化（如被对端清理）：重查一次偏移后重试。
          if (err.status != 416) rethrow;
          final retryStart = start > 0
              ? 0
              : await client
                  .resumeOffset(mapping, e.relativePath, e.size, e.mtimeMs)
                  .timeout(AppConstants.controlTimeout);
          await client.upload(
            mapping,
            e.relativePath,
            File(srcFile),
            mtimeMs: e.mtimeMs,
            start: retryStart,
          );
        }
        onProgress(i + 1 - failed, total, e);
      } catch (err) {
        failed++;
        onFailure?.call(e, err);
      }
    }
    return failed;
  }

  /// 拉取单个文件：分片续传 + 原子落盘 + 回写 mtime。
  static Future<void> _pullOne(
    SyncMapping mapping,
    PeerClient client,
    FileEntry e,
  ) async {
    final root = mapping.destPath;
    final rel = e.relativePath;
    if (!isValidRelPath(rel)) {
      throw const TransferException(400, 'PATH_INVALID', '对端返回了非法路径');
    }
    final part = PartStore.partFile(root, rel);

    final offset = await PartStore.currentOffset(root, rel, e.size, e.mtimeMs);
    await PartStore.writeMeta(
      root,
      rel,
      PartMeta(path: rel, size: e.size, mtime: e.mtimeMs),
    );

    if (offset < e.size) {
      await client.download(mapping, e, part, start: offset);
    } else if (!await part.exists()) {
      // 空文件不会触发下载，需显式创建 0 字节分片以便后续原子改名。
      await part.parent.create(recursive: true);
      await part.writeAsBytes(const <int>[]);
    }

    final received = await part.length();
    if (received > e.size) {
      await PartStore.discard(root, rel);
      throw const TransferException(409, 'INCOMPLETE', '数据超出预期大小，已重置分片');
    }
    if (received != e.size) {
      throw const TransferException(409, 'INCOMPLETE', '拉取数据不完整，已保留分片');
    }

    final dst = LocalIndexService.safeFile(root, rel);
    if (dst == null) {
      throw const TransferException(400, 'PATH_INVALID', '路径非法');
    }
    await dst.parent.create(recursive: true);
    try {
      await part.rename(dst.path);
    } on FileSystemException {
      if (await dst.exists()) await dst.delete();
      await part.rename(dst.path);
    }
    if (e.mtimeMs > 0) {
      try {
        await dst.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(e.mtimeMs),
        );
      } catch (_) {}
    }
    await PartStore.discard(root, rel);
  }
}
