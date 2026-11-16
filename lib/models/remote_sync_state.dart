import 'package:flutter/foundation.dart';

/// 对端发起的同步，以本机视角记录发送和接收。
class RemoteSyncState {
  final String task;
  final String peerName;
  final String mappingName;
  final int total;
  final int sentCount;
  final int receivedCount;
  final int sentBytes;
  final int receivedBytes;
  final int transferredBytes;
  final int failed;
  final String currentName;
  final bool sending;
  final bool preparing;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final DateTime? transferStartedAt;
  final double inFlight;
  final String? error;

  const RemoteSyncState(
      {required this.task,
      required this.peerName,
      required this.mappingName,
      required this.total,
      required this.startedAt,
      this.sentCount = 0,
      this.receivedCount = 0,
      this.sentBytes = 0,
      this.receivedBytes = 0,
      this.transferredBytes = 0,
      this.failed = 0,
      this.currentName = '',
      this.sending = false,
      this.preparing = true,
      this.finishedAt,
      this.transferStartedAt,
      this.inFlight = 0,
      this.error});

  int get done => sentCount + receivedCount;
  double get fraction =>
      total == 0 ? 0 : ((done + inFlight) / total).clamp(0.0, 1.0).toDouble();
  double get speed {
    if (transferStartedAt == null) return 0;
    final us = (finishedAt ?? DateTime.now())
        .difference(transferStartedAt!)
        .inMicroseconds;
    return us <= 0 ? 0 : transferredBytes * 1e6 / us;
  }

  bool get finished => finishedAt != null;

  RemoteSyncState copyWith(
          {double? inFlight,
          DateTime? transferStartedAt,
          int? total,
          int? sentCount,
          int? receivedCount,
          int? sentBytes,
          int? receivedBytes,
          int? transferredBytes,
          int? failed,
          String? currentName,
          bool? sending,
          bool? preparing,
          DateTime? finishedAt,
          String? error}) =>
      RemoteSyncState(
          task: task,
          peerName: peerName,
          mappingName: mappingName,
          startedAt: startedAt,
          inFlight: inFlight ?? this.inFlight,
          transferStartedAt: transferStartedAt ?? this.transferStartedAt,
          total: total ?? this.total,
          sentCount: sentCount ?? this.sentCount,
          receivedCount: receivedCount ?? this.receivedCount,
          sentBytes: sentBytes ?? this.sentBytes,
          receivedBytes: receivedBytes ?? this.receivedBytes,
          transferredBytes: transferredBytes ?? this.transferredBytes,
          failed: failed ?? this.failed,
          currentName: currentName ?? this.currentName,
          sending: sending ?? this.sending,
          preparing: preparing ?? this.preparing,
          finishedAt: finishedAt ?? this.finishedAt,
          error: error ?? this.error);
}

/// 只从服务端实际文件流累计字节；最多每 100ms 刷新一次界面。
class RemoteSyncTracker extends ValueNotifier<RemoteSyncState?> {
  RemoteSyncTracker() : super(null);
  final Stopwatch _updates = Stopwatch();
  int _bytes = 0;
  final Map<String, double> _partial = {};
  final Map<String, int> _sizes = {};
  double get _inFlight => _partial.values.fold(0, (sum, value) => sum + value);

  bool active(String task) => value?.task == task && !value!.finished;

  void begin(
      {required String task,
      required String peerName,
      required String mappingName,
      required int total}) {
    if (value?.task == task) return;
    _bytes = 0;
    _partial.clear();
    _sizes.clear();
    _updates
      ..reset()
      ..start();
    value = RemoteSyncState(
        task: task,
        peerName: peerName,
        mappingName: mappingName,
        total: total,
        startedAt: DateTime.now());
  }

  void planned(String task, int total) {
    if (!active(task)) return;
    value = value!.copyWith(total: total, preparing: false);
  }

  void fileStarted(String task, String path,
      {required bool sending, int size = 0, int offset = 0}) {
    if (!active(task)) return;
    _sizes[path] = size;
    _partial[path] = size == 0 ? 0 : (offset / size).clamp(0.0, 1.0).toDouble();
    value = value!.copyWith(
        currentName: path,
        sending: sending,
        preparing: false,
        inFlight: _inFlight,
        transferStartedAt: value!.transferStartedAt ?? DateTime.now());
  }

  void transferred(String task, int bytes, {String? path}) {
    if (!active(task)) return;
    _bytes += bytes;
    final name = path ?? value!.currentName;
    final size = _sizes[name] ?? 0;
    if (size > 0) {
      _partial[name] =
          ((_partial[name] ?? 0) + bytes / size).clamp(0.0, 1.0).toDouble();
    }
    if (_updates.elapsedMilliseconds >= 100 || value!.transferredBytes == 0) {
      _updates.reset();
      value = value!.copyWith(transferredBytes: _bytes, inFlight: _inFlight);
    }
  }

  void fileCompleted(String task, int size,
      {required bool sending, String? path}) {
    if (!active(task)) return;
    final name = path ?? value!.currentName;
    _partial.remove(name);
    _sizes.remove(name);
    final s = value!;
    value = s.copyWith(
        inFlight: _inFlight,
        transferredBytes: _bytes,
        sentCount: s.sentCount + (sending ? 1 : 0),
        receivedCount: s.receivedCount + (sending ? 0 : 1),
        sentBytes: s.sentBytes + (sending ? size : 0),
        receivedBytes: s.receivedBytes + (sending ? 0 : size));
  }

  void finish(String task,
      {int? sentCount, int? receivedCount, int failed = 0, String? error}) {
    if (!active(task)) return;
    value = value!.copyWith(
        sentCount: sentCount,
        receivedCount: receivedCount,
        transferredBytes: _bytes,
        failed: failed,
        error: error,
        preparing: false,
        finishedAt: DateTime.now());
    _updates.stop();
  }

  void interrupted(String task, String message) => finish(task, error: message);
}
