import 'file_entry.dart';

/// 一次同步的差异计算结果。
class SyncPlan {
  final String mappingId;
  final String mappingName;

  /// 需要从发送端下载的文件（新增 + 变更）。
  final List<FileEntry> toSend;

  /// 仅「新增」的文件（路径在目标端不存在）。
  final List<FileEntry> newOnly;

  /// 仅「变更」的文件（路径相同但内容不同）。
  final List<FileEntry> changedOnly;

  const SyncPlan({
    required this.mappingId,
    required this.mappingName,
    required this.toSend,
    required this.newOnly,
    required this.changedOnly,
  });

  int get totalBytes => toSend.fold(0, (sum, e) => sum + e.size);

  bool get isEmpty => toSend.isEmpty;
}
