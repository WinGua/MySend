import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 一条同步任务日志。
class SyncLogEntry {
  final String mappingName; // 任务名称
  final DateTime time;
  final int fileCount; // 同步文件总数
  final int totalBytes; // 总大小

  const SyncLogEntry({
    required this.mappingName,
    required this.time,
    required this.fileCount,
    required this.totalBytes,
  });

  Map<String, dynamic> toJson() => {
        'name': mappingName,
        'time': time.millisecondsSinceEpoch,
        'count': fileCount,
        'bytes': totalBytes,
      };

  factory SyncLogEntry.fromJson(Map<String, dynamic> j) => SyncLogEntry(
        mappingName: j['name'] as String? ?? '',
        time: DateTime.fromMillisecondsSinceEpoch((j['time'] as num?)?.toInt() ?? 0),
        fileCount: (j['count'] as num?)?.toInt() ?? 0,
        totalBytes: (j['bytes'] as num?)?.toInt() ?? 0,
      );
}

/// 同步日志仓库：持久化为本地 JSON，自动清理超 7 天的记录。
class SyncLogRepository extends ChangeNotifier {
  static const String _fileName = 'music_sync_logs.json';
  static const Duration _retention = Duration(days: 7);

  final List<SyncLogEntry> _entries = [];
  bool _loaded = false;

  /// 按时间倒序（最新在前）。
  List<SyncLogEntry> get entries => List.unmodifiable(_entries);
  bool get loaded => _loaded;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _fileName));
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final raw = await file.readAsString();
        final list = (jsonDecode(raw) as List<dynamic>)
            .map((e) => SyncLogEntry.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        _entries
          ..clear()
          ..addAll(list);
      }
    } catch (_) {
      // 日志损坏则从空开始。
    }
    prune();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
        flush: true,
      );
    } catch (e) {
      debugPrint('保存同步日志失败: $e');
    }
  }

  /// 记录一次同步（任务名、时间、文件数、总大小）。
  Future<void> add({
    required String name,
    required int fileCount,
    required int totalBytes,
  }) async {
    _entries.insert(
      0,
      SyncLogEntry(
        mappingName: name,
        time: DateTime.now(),
        fileCount: fileCount,
        totalBytes: totalBytes,
      ),
    );
    prune();
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    await _save();
  }

  /// 移除超过保留期的记录。
  void prune() {
    final cutoff = DateTime.now().subtract(_retention);
    _entries.removeWhere((e) => e.time.isBefore(cutoff));
  }
}