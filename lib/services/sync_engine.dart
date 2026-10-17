import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../models/file_entry.dart';
import '../models/sync_mapping.dart';
import '../models/sync_plan.dart';
import 'transfer/receiver_client.dart';
import 'transfer/sender_client.dart';

/// 同步引擎：计算差异、执行单向传输（发送端 → 接收端）。
///
/// 规则：
/// - 「新增」= 发送端索引中存在、接收端不存在的相对路径 → 待传。
/// - 只同步新增文件，不比对内容、不处理删除。
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

  /// 依次下载 [files] 到接收端 [mapping.destPath] 对应子目录。
  ///
  /// 返回失败的文件数：单个文件失败不会中断整个任务，跳过并继续，
  /// 避免「连续传输多文件后某个文件卡住导致任务整体死等」。
  static Future<int> run({
    required SyncMapping mapping,
    required ReceiverClient client,
    required List<FileEntry> files,
    required void Function(int done, int total, FileEntry current) onProgress,
  }) async {
    final total = files.length;
    var failed = 0;
    try {
      for (var i = 0; i < total; i++) {
        final e = files[i];
        final destFile = p.join(
          mapping.destPath,
          e.relativePath.replaceAll('/', Platform.pathSeparator),
        );
        try {
          await client
              .downloadFile(mapping.name, e.relativePath, destFile, mtimeMs: e.mtimeMs)
              .timeout(_fileTimeout(e.size));
          onProgress(i + 1 - failed, total, e);
        } catch (_) {
          failed++;
        }
      }
    } finally {
      client.close();
    }
    return failed;
  }

  /// 依次把 [files] 从发送端推送到接收端（供 PC 发起同步时使用）。
  ///
  /// 返回失败的文件数（语义同 [run]）。
  static Future<int> push({
    required SyncMapping mapping,
    required SenderClient client,
    required List<FileEntry> files,
    required void Function(int done, int total, FileEntry current) onProgress,
  }) async {
    final total = files.length;
    var failed = 0;
    try {
      for (var i = 0; i < total; i++) {
        final e = files[i];
        final srcFile = p.join(
          mapping.sourcePath,
          e.relativePath.replaceAll('/', Platform.pathSeparator),
        );
        try {
          await client
              .uploadFile(mapping.name, e.relativePath, srcFile)
              .timeout(_fileTimeout(e.size));
          onProgress(i + 1 - failed, total, e);
        } catch (_) {
          failed++;
        }
      }
    } finally {
      client.close();
    }
    return failed;
  }

  /// 单个文件的传输超时：按文件大小保守估算（约 256KB/s），
  /// 下限 30 秒、上限 10 分钟，覆盖小文件卡死与大文件正常传输。
  static Duration _fileTimeout(int bytes) {
    var sec = (bytes / (256 * 1024)).ceil();
    if (sec < 30) sec = 30;
    if (sec > 600) sec = 600;
    return Duration(seconds: sec);
  }
}