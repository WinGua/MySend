import 'file_entry.dart';

/// 一次同步的差异计算结果。
class SyncPlan {
  final String mappingId;
  final String mappingName;

  /// 需要从发送端下载的新增文件（接收端不存在的相对路径）。
  final List<FileEntry> toSend;

  /// 语义别名，与 [toSend] 一致（仅「新增」）。
  final List<FileEntry> newOnly;

  const SyncPlan({
    required this.mappingId,
    required this.mappingName,
    required this.toSend,
    required this.newOnly,
  });

  int get totalBytes => toSend.fold(0, (sum, e) => sum + e.size);

  bool get isEmpty => toSend.isEmpty;
}