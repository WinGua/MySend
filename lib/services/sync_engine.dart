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

/// 单个文件的传输方向（以本机视角）。
enum SyncDirection { push, pull }

/// 一次双向同步的执行结果。
class SyncResult {
  final int pushed;
  final int pulled;
  final int pushFailed;
  final int pullFailed;

  const SyncResult({
    required this.pushed,
    required this.pulled,
    required this.pushFailed,
    required this.pullFailed,
  });

  int get failed => pushFailed + pullFailed;

  bool get success => failed == 0;
}

/// 同步引擎：计算双向差异、执行互补传输。
///
/// 规则：
/// - 「本机有、对端无」→ 本机发送
/// - 「对端有、本机无」→ 本机接收
/// - 两端都有 → 跳过，不比对内容、不覆盖、不删除
/// - 传输走协议 v2：先落 `.mysend-part` 分片，完成后原子改名
class SyncEngine {
  SyncEngine._();

  static SyncPlan computeBidirectionalPlan({
    required SyncMapping mapping,
    required Map<String, FileEntry> local,
    required Map<String, FileEntry> remote,
  }) {
    final toPush = <FileEntry>[];
    final toPull = <FileEntry>[];
    var skipped = 0;

    for (final e in local.values) {
      if (remote.containsKey(e.relativePath)) {
        skipped++;
      } else {
        toPush.add(e);
      }
    }
    for (final e in remote.values) {
      if (!local.containsKey(e.relativePath)) {
        toPull.add(e);
      }
    }

    toPush.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    toPull.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    return SyncPlan(
      mappingId: mapping.id,
      mappingName: mapping.name,
      toPush: toPush,
      toPull: toPull,
      skippedCount: skipped,
    );
  }

  /// 执行双向同步：先发送本机新增，再接收对端新增。
  ///
  /// [localRoot] 为本机在该映射中的根目录，发送与接收都读写它。
  /// 单个文件失败不中断任务，结果按方向分别计数。
  static Future<SyncResult> runBidirectional({
    required SyncMapping mapping,
    required PeerClient client,
    required SyncPlan plan,
    required String localRoot,
    required void Function(
      int done,
      int total,
      FileEntry current,
      SyncDirection direction,
    ) onProgress,
    void Function(FileEntry entry, SyncDirection direction, Object error)?
        onFailure,
  }) async {
    final total = plan.totalCount;
    var done = 0;
    var pushed = 0;
    var pulled = 0;
    var pushFailed = 0;
    var pullFailed = 0;

    if (plan.toPush.isNotEmpty) {
      // 先批量查询续传偏移，正常情况整批文件只需一次请求。
      var offsets = const <String, int>{};
      try {
        final merged = <String, int>{};
        const chunkSize = 2000;
        for (var i = 0; i < plan.toPush.length; i += chunkSize) {
          final end = (i + chunkSize < plan.toPush.length)
              ? i + chunkSize
              : plan.toPush.length;
          merged.addAll(
            await client.resumeOffsets(mapping, plan.toPush.sublist(i, end)),
          );
        }
        offsets = merged;
      } catch (_) {
        // 对端不支持批量查询时回退为逐文件查询。
      }

      for (final e in plan.toPush) {
        try {
          await _pushOne(
            mapping,
            client,
            e,
            localRoot,
            offsets[e.relativePath],
          );
          pushed++;
          done++;
          onProgress(done, total, e, SyncDirection.push);
        } catch (err) {
          pushFailed++;
          onFailure?.call(e, SyncDirection.push, err);
        }
      }
    }

    for (final e in plan.toPull) {
      try {
        await _pullOne(mapping, client, e, localRoot);
        pulled++;
        done++;
        onProgress(done, total, e, SyncDirection.pull);
      } catch (err) {
        pullFailed++;
        onFailure?.call(e, SyncDirection.pull, err);
      }
    }

    return SyncResult(
      pushed: pushed,
      pulled: pulled,
      pushFailed: pushFailed,
      pullFailed: pullFailed,
    );
  }

  /// 推送单个文件（含断点续传与偏移失效重试）。
  static Future<void> _pushOne(
    SyncMapping mapping,
    PeerClient client,
    FileEntry e,
    String localRoot,
    int? knownOffset,
  ) async {
    final srcFile = p.join(
      localRoot,
      e.relativePath.replaceAll('/', Platform.pathSeparator),
    );
    final start = knownOffset ??
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
      // 目标已存在说明对端在对比后已拥有该文件，按成功跳过处理。
      if (err.code == 'ALREADY_EXISTS') return;
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
  }

  /// 拉取单个文件：分片续传 + 原子落盘 + 回写 mtime。
  static Future<void> _pullOne(
    SyncMapping mapping,
    PeerClient client,
    FileEntry e,
    String localRoot,
  ) async {
    final root = localRoot;
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
