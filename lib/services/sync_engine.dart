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
import 'transfer/local_transfer_server.dart';

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

class SyncByteProgress {
  final double fraction;
  final double speed;
  final FileEntry current;
  final SyncDirection direction;
  final int done;
  final int total;
  const SyncByteProgress(
      this.fraction, this.speed, this.current, this.direction,
      {required this.done, required this.total});
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
    required LocalTransferServer localServer,
    required SyncPlan plan,
    required String localRoot,
    void Function(int bytes)? onTransferBytes,
    void Function(SyncByteProgress progress)? onTransferProgress,
    required void Function(
      int done,
      int total,
      FileEntry current,
      SyncDirection direction,
    ) onProgress,
    void Function(FileEntry entry, SyncDirection direction, Object error)?
        onFailure,
  }) =>
      client.withSyncSession(localServer, () async {
        await client.sendSyncStatus({
          'phase': 'start',
          'name': mapping.name,
          'peer': client.deviceName.length <= 128
              ? client.deviceName
              : client.deviceName.substring(0, 128),
          'total': plan.totalCount,
        });
        try {
          // 取得两端锁后重新扫描，接收端此时显示「准备同步」。
          final indexes = await Future.wait([
            LocalIndexService.scan(localRoot),
            client.fetchIndex(mapping.name).then((files) => {
                  for (final e in files) e.relativePath: e,
                }),
          ]);
          final currentPlan = computeBidirectionalPlan(
              mapping: mapping, local: indexes[0], remote: indexes[1]);
          await client.sendSyncStatus(
              {'phase': 'plan', 'total': currentPlan.totalCount});
          final result = await _run(
              mapping: mapping,
              client: client,
              plan: currentPlan,
              localRoot: localRoot,
              onTransferBytes: onTransferBytes,
              onTransferProgress: onTransferProgress,
              onProgress: onProgress,
              onFailure: onFailure);
          await client.sendSyncStatus({
            'phase': 'end',
            'sent': result.pushed,
            'received': result.pulled,
            'failed': result.failed
          });
          return result;
        } catch (e) {
          final error = '$e';
          try {
            await client.sendSyncStatus({
              'phase': 'end',
              'sent': 0,
              'received': 0,
              'failed': 0,
              'error': error.length <= 2000 ? error : error.substring(0, 2000)
            });
          } catch (_) {
            // 无法通知时由服务端释放/租约过期事件结束接收端窗口。
          }
          rethrow;
        }
      });

  static Future<SyncResult> _run({
    required SyncMapping mapping,
    required PeerClient client,
    required SyncPlan plan,
    required String localRoot,
    void Function(int bytes)? onTransferBytes,
    void Function(SyncByteProgress progress)? onTransferProgress,
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
    final partial = <String, double>{};
    final clock = Stopwatch();
    var wireBytes = 0;
    var lastUpdate = -100;
    void reportBytes(FileEntry entry, SyncDirection direction, int bytes,
        {int? offset}) {
      if (!clock.isRunning) clock.start();
      if (offset != null) {
        partial[entry.relativePath] = entry.size == 0 ? 0 : offset / entry.size;
      } else {
        wireBytes += bytes;
        onTransferBytes?.call(bytes);
        if (entry.size > 0) {
          partial[entry.relativePath] =
              ((partial[entry.relativePath] ?? 0) + bytes / entry.size)
                  .clamp(0.0, 1.0)
                  .toDouble();
        }
      }
      if (offset != null || clock.elapsedMilliseconds - lastUpdate >= 100) {
        lastUpdate = clock.elapsedMilliseconds;
        final equivalent =
            done + partial.values.fold<double>(0, (sum, value) => sum + value);
        onTransferProgress?.call(SyncByteProgress(
            total == 0 ? 0 : (equivalent / total).clamp(0.0, 1.0).toDouble(),
            clock.elapsedMicroseconds == 0
                ? 0
                : wireBytes * 1e6 / clock.elapsedMicroseconds,
            entry,
            direction,
            done: done,
            total: total));
      }
    }

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

      await _parallel(plan.toPush, (e) async {
        try {
          await _pushOne(
            mapping,
            client,
            e,
            localRoot,
            offsets[e.relativePath],
            (bytes) => reportBytes(e, SyncDirection.push, bytes),
            (offset) => reportBytes(e, SyncDirection.push, 0, offset: offset),
          );
          reportBytes(e, SyncDirection.push, 0, offset: e.size);
          partial.remove(e.relativePath);
          pushed++;
          done++;
          onProgress(done, total, e, SyncDirection.push);
        } catch (err) {
          if (client.cancelled) rethrow;
          pushFailed++;
          onFailure?.call(e, SyncDirection.push, err);
        }
      });
    }

    await _parallel(plan.toPull, (e) async {
      try {
        await _pullOne(
            mapping,
            client,
            e,
            localRoot,
            (bytes) => reportBytes(e, SyncDirection.pull, bytes),
            (offset) => reportBytes(e, SyncDirection.pull, 0, offset: offset));
        reportBytes(e, SyncDirection.pull, 0, offset: e.size);
        partial.remove(e.relativePath);
        pulled++;
        done++;
        onProgress(done, total, e, SyncDirection.pull);
      } catch (err) {
        if (client.cancelled) rethrow;
        pullFailed++;
        onFailure?.call(e, SyncDirection.pull, err);
      }
    });

    return SyncResult(
      pushed: pushed,
      pulled: pulled,
      pushFailed: pushFailed,
      pullFailed: pullFailed,
    );
  }

  static Future<void> _parallel(
      List<FileEntry> files, Future<void> Function(FileEntry) transfer) async {
    var next = 0;
    Future<void> worker() async {
      while (next < files.length) {
        final entry = files[next++];
        await transfer(entry);
      }
    }

    await Future.wait(
        List.generate(files.length < 4 ? files.length : 4, (_) => worker()));
  }

  /// 推送单个文件（含断点续传与偏移失效重试）。
  static Future<void> _pushOne(
    SyncMapping mapping,
    PeerClient client,
    FileEntry e,
    String localRoot,
    int? knownOffset,
    void Function(int bytes)? onBytes,
    void Function(int offset)? onStarted,
  ) async {
    final srcFile = p.join(
      localRoot,
      e.relativePath.replaceAll('/', Platform.pathSeparator),
    );
    final start = knownOffset ??
        await client
            .resumeOffset(mapping, e.relativePath, e.size, e.mtimeMs)
            .timeout(AppConstants.controlTimeout);
    onStarted?.call(start);
    try {
      await client.upload(
        mapping,
        e.relativePath,
        File(srcFile),
        mtimeMs: e.mtimeMs,
        start: start,
        onBytes: onBytes,
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
      onStarted?.call(retryStart);
      await client.upload(
        mapping,
        e.relativePath,
        File(srcFile),
        mtimeMs: e.mtimeMs,
        start: retryStart,
        onBytes: onBytes,
      );
    }
  }

  /// 拉取单个文件：分片续传 + 原子落盘 + 回写 mtime。
  static Future<void> _pullOne(
    SyncMapping mapping,
    PeerClient client,
    FileEntry e,
    String localRoot,
    void Function(int bytes)? onBytes,
    void Function(int offset)? onStarted,
  ) async {
    final root = localRoot;
    final rel = e.relativePath;
    if (!isValidRelPath(rel)) {
      throw const TransferException(400, 'PATH_INVALID', '对端返回了非法路径');
    }
    final dst = LocalIndexService.safeFile(root, rel);
    if (dst == null) throw const TransferException(400, 'PATH_INVALID', '路径非法');
    if (await dst.exists()) return;
    final part = PartStore.partFile(root, rel);

    final offset = await PartStore.currentOffset(root, rel, e.size, e.mtimeMs);
    await PartStore.writeMeta(
      root,
      rel,
      PartMeta(path: rel, size: e.size, mtime: e.mtimeMs),
    );

    onStarted?.call(offset);
    if (offset < e.size) {
      await client.download(mapping, e, part, start: offset, onBytes: onBytes);
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

    await dst.parent.create(recursive: true);
    if (await dst.exists()) return;
    await part.rename(dst.path);
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
