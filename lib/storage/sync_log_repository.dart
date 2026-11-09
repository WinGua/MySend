import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/utils.dart';

/// 一条同步任务日志，按「本机视角」区分发送与接收。
class SyncLogEntry {
  final String mappingName;
  final DateTime time;

  /// 对端设备名，旧记录为空。
  final String peerName;

  final int sentCount;
  final int sentBytes;
  final List<String> sentFiles;

  final int receivedCount;
  final int receivedBytes;
  final List<String> receivedFiles;

  const SyncLogEntry({
    required this.mappingName,
    required this.time,
    this.peerName = '',
    this.sentCount = 0,
    this.sentBytes = 0,
    this.sentFiles = const [],
    this.receivedCount = 0,
    this.receivedBytes = 0,
    this.receivedFiles = const [],
  });

  int get fileCount => sentCount + receivedCount;

  int get totalBytes => sentBytes + receivedBytes;

  Map<String, dynamic> toJson() => {
        'name': mappingName,
        'time': time.millisecondsSinceEpoch,
        'peer': peerName,
        'sent': {'c': sentCount, 'b': sentBytes, 'f': sentFiles},
        'recv': {'c': receivedCount, 'b': receivedBytes, 'f': receivedFiles},
        // 旧版本只认识合计字段，保留以兼容降级读取。
        'count': sentCount + receivedCount,
        'bytes': sentBytes + receivedBytes,
        'files': [...sentFiles, ...receivedFiles],
      };

  /// [legacyAsSent] 用于旧记录迁移：旧版电脑端日志都是「发出」，
  /// 旧版安卓端日志都是「接收」。
  factory SyncLogEntry.fromJson(
    Map<String, dynamic> j, {
    required bool legacyAsSent,
  }) {
    final sent = _bucket(j['sent']);
    final recv = _bucket(j['recv']);
    final time = DateTime.fromMillisecondsSinceEpoch(
      (j['time'] as num?)?.toInt() ?? 0,
    );
    if (sent != null || recv != null) {
      return SyncLogEntry(
        mappingName: j['name'] as String? ?? '',
        time: time,
        peerName: j['peer'] as String? ?? '',
        sentCount: sent?.count ?? 0,
        sentBytes: sent?.bytes ?? 0,
        sentFiles: sent?.files ?? const [],
        receivedCount: recv?.count ?? 0,
        receivedBytes: recv?.bytes ?? 0,
        receivedFiles: recv?.files ?? const [],
      );
    }

    final files = (j['files'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();
    final count = (j['count'] as num?)?.toInt() ?? files.length;
    final bytes = (j['bytes'] as num?)?.toInt() ?? 0;
    return SyncLogEntry(
      mappingName: j['name'] as String? ?? '',
      time: time,
      peerName: j['peer'] as String? ?? '',
      sentCount: legacyAsSent ? count : 0,
      sentBytes: legacyAsSent ? bytes : 0,
      sentFiles: legacyAsSent ? files : const [],
      receivedCount: legacyAsSent ? 0 : count,
      receivedBytes: legacyAsSent ? 0 : bytes,
      receivedFiles: legacyAsSent ? const [] : files,
    );
  }

  static _LogBucket? _bucket(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final files = (map['f'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();
    return _LogBucket(
      count: (map['c'] as num?)?.toInt() ?? files.length,
      bytes: (map['b'] as num?)?.toInt() ?? 0,
      files: files,
    );
  }
}

class _LogBucket {
  final int count;
  final int bytes;
  final List<String> files;

  const _LogBucket({
    required this.count,
    required this.bytes,
    required this.files,
  });
}

/// 同步日志仓库：持久化为本地 JSON，自动清理超 7 天的记录。
class SyncLogRepository extends ChangeNotifier {
  static const Duration _retention = Duration(days: 7);

  final List<SyncLogEntry> _entries = [];
  bool _loaded = false;

  /// 按时间倒序（最新在前）。
  List<SyncLogEntry> get entries => List.unmodifiable(_entries);
  bool get loaded => _loaded;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, AppConstants.logFileName));
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final raw = await file.readAsString();
        final list = (jsonDecode(raw) as List<dynamic>)
            .map((e) => SyncLogEntry.fromJson(
                  Map<String, dynamic>.from(e as Map),
                  legacyAsSent: isSender,
                ))
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

  /// 记录一次同步：文件清单只保存文件名，按发送/接收分列。
  Future<void> add({
    required String name,
    required DateTime time,
    String peerName = '',
    int sentCount = 0,
    int sentBytes = 0,
    List<String> sentFiles = const [],
    int receivedCount = 0,
    int receivedBytes = 0,
    List<String> receivedFiles = const [],
  }) async {
    _entries.insert(
      0,
      SyncLogEntry(
        mappingName: name,
        time: time,
        peerName: peerName,
        sentCount: sentCount,
        sentBytes: sentBytes,
        sentFiles: sentFiles,
        receivedCount: receivedCount,
        receivedBytes: receivedBytes,
        receivedFiles: receivedFiles,
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
