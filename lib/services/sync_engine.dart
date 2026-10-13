import 'dart:io';
import 'package:path/path.dart' as p;

import '../models/file_entry.dart';
import '../models/sync_mapping.dart';
import '../models/sync_plan.dart';
import 'transfer/receiver_client.dart';

/// 同步引擎：计算差异、执行单向传输（发送端 → 接收端）。
///
/// 规则：
/// - 「新增」= 发送端索引中存在、接收端不存在的相对路径 → 必传。
/// - 「变更」= 路径相同但大小或修改时间不同 → 由 includeChanged 开关决定是否传。
/// - 不考虑删除（删除由用户手动处理）。
class SyncEngine {
  SyncEngine._();

  static SyncPlan computePlan({
    required SyncMapping mapping,
    required Map<String, FileEntry> source,
    required Map<String, FileEntry> dest,
    required bool includeChanged,
  }) {
    final newOnly = <FileEntry>[];
    final changedOnly = <FileEntry>[];

    for (final e in source.values) {
      final d = dest[e.relativePath];
      if (d == null) {
        newOnly.add(e);
      } else if (!d.sameContentAs(e)) {
        changedOnly.add(e);
      }
    }

    final toSend = <FileEntry>[...newOnly];
    if (includeChanged) toSend.addAll(changedOnly);
    toSend.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    return SyncPlan(
      mappingId: mapping.id,
      mappingName: mapping.name,
      toSend: toSend,
      newOnly: newOnly,
      changedOnly: changedOnly,
    );
  }

  /// 依次下载 [files] 到接收端 [mapping.destPath] 对应子目录。
  static Future<void> run({
    required SyncMapping mapping,
    required ReceiverClient client,
    required List<FileEntry> files,
    required void Function(int done, int total, FileEntry current) onProgress,
  }) async {
    final total = files.length;
    for (var i = 0; i < total; i++) {
      final e = files[i];
      final destFile = p.join(
        mapping.destPath,
        e.relativePath.replaceAll('/', Platform.pathSeparator),
      );
      await client.downloadFile(mapping.name, e.relativePath, destFile, mtimeMs: e.mtimeMs);
      onProgress(i + 1, total, e);
    }
  }
}