import 'file_entry.dart';

/// 一次双向对比的差异计算结果。
///
/// 以「本机」视角命名：
/// - [toPush]：本机有、对端没有 → 本机发出
/// - [toPull]：对端有、本机没有 → 本机接收
/// - [skippedCount]：两端都存在 → 跳过，不比对内容、不覆盖、不删除
class SyncPlan {
  final String mappingId;
  final String mappingName;

  final List<FileEntry> toPush;
  final List<FileEntry> toPull;
  final int skippedCount;

  const SyncPlan({
    required this.mappingId,
    required this.mappingName,
    required this.toPush,
    required this.toPull,
    required this.skippedCount,
  });

  int get pushBytes => toPush.fold(0, (sum, e) => sum + e.size);

  int get pullBytes => toPull.fold(0, (sum, e) => sum + e.size);

  int get totalCount => toPush.length + toPull.length;

  int get totalBytes => pushBytes + pullBytes;

  bool get isEmpty => toPush.isEmpty && toPull.isEmpty;
}
