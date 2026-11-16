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
      this.error});

  int get done => sentCount + receivedCount;
  bool get finished => finishedAt != null;

  RemoteSyncState copyWith(
          {int? total,
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

  bool active(String task) => value?.task == task && !value!.finished;

  void begin(
      {required String task,
      required String peerName,
      required String mappingName,
      required int total}) {
    if (value?.task == task) return;
    _bytes = 0;
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

  void fileStarted(String task, String path, {required bool sending}) {
    if (!active(task)) return;
    value =
        value!.copyWith(currentName: path, sending: sending, preparing: false);
  }

  void transferred(String task, int bytes) {
    if (!active(task)) return;
    _bytes += bytes;
    if (_updates.elapsedMilliseconds >= 100) {
      _updates.reset();
      value = value!.copyWith(transferredBytes: _bytes);
    }
  }

  void fileCompleted(String task, int size, {required bool sending}) {
    if (!active(task)) return;
    final s = value!;
    value = s.copyWith(
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
