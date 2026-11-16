import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:fluent_ui/fluent_ui.dart';

import '../../core/utils.dart';
import '../../models/file_entry.dart';
import '../../models/remote_sync_state.dart';
import '../../services/sync_engine.dart';
import '../../services/transfer/peer_client.dart';
import 'glass.dart';

const _danger = Color(0xFFFF9B9B);
const _warning = Color(0xFFFFC46B);
const _muted = Color(0xFF8A8A8A);

class _SyncProgress {
  final int done;
  final int total;
  final int sentCount;
  final int receivedCount;
  final int sentBytes;
  final int receivedBytes;
  final int transferredBytes;
  final String currentName;
  final SyncDirection? direction;
  final double? fraction;
  final double? speed;

  const _SyncProgress({
    this.done = 0,
    this.total = 0,
    this.sentCount = 0,
    this.receivedCount = 0,
    this.sentBytes = 0,
    this.receivedBytes = 0,
    this.transferredBytes = 0,
    this.currentName = '',
    this.direction,
    this.fraction,
    this.speed,
  });

  _SyncProgress withTransferredBytes(int bytes) => _SyncProgress(
        done: done,
        total: total,
        sentCount: sentCount,
        receivedCount: receivedCount,
        sentBytes: sentBytes,
        receivedBytes: receivedBytes,
        currentName: currentName,
        direction: direction,
        transferredBytes: bytes,
        fraction: fraction,
        speed: speed,
      );

  int get totalBytes => sentBytes + receivedBytes;
}

/// 同步进度弹窗：总进度 + 发送/接收分项 + 当前文件 + 速度，完成后需手动关闭。
class SyncDialog extends StatefulWidget {
  final String mappingName;

  /// 同步过程中收集到的失败原因（最多 20 条），由调用方持有。
  final List<String> failures;
  final Future<SyncResult> Function(
    void Function(int done, int total, FileEntry current, SyncDirection dir)
        onProgress,
    void Function(int bytes) onBytes,
    void Function(SyncByteProgress progress) onTransferProgress,
  )? run;
  final ValueListenable<RemoteSyncState?>? remote;
  final ValueListenable<RemoteSyncState?>? incoming;

  const SyncDialog({
    super.key,
    required this.mappingName,
    required this.failures,
    required this.run,
    this.incoming,
  }) : remote = null;

  const SyncDialog.remote({super.key, required this.remote})
      : mappingName = '',
        failures = const [],
        incoming = null,
        run = null;

  @override
  State<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<SyncDialog> {
  final ValueNotifier<_SyncProgress> _progress =
      ValueNotifier(const _SyncProgress());
  bool _running = true;
  String? _error;
  SyncResult? _result;
  final Stopwatch _watch = Stopwatch();
  int _wireBytes = 0;
  int _lastByteUpdate = 0;
  String? _remoteTask;
  bool _busyRejected = false;

  @override
  void initState() {
    super.initState();
    _watch.start();
    if (widget.remote == null) {
      widget.incoming?.addListener(_incomingChanged);
      _start();
    } else {
      widget.remote!.addListener(_receive);
      _receive();
    }
  }

  @override
  void dispose() {
    widget.remote?.removeListener(_receive);
    widget.incoming?.removeListener(_incomingChanged);
    _progress.dispose();
    super.dispose();
  }

  void _incomingChanged() {
    _discardBusyDialog();
  }

  bool _discardBusyDialog() {
    final incoming = widget.incoming?.value;
    if (!mounted || !_busyRejected || incoming == null || incoming.finished) {
      return false;
    }
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return false;
    // 两端同时点击而本端未取得锁时，用对端的进度窗口接替忙碌提示。
    Navigator.of(context).removeRoute(route);
    return true;
  }

  void _receive() {
    final state = widget.remote!.value;
    if (state == null) return;
    if (_remoteTask != state.task) {
      _remoteTask = state.task;
      _watch
        ..reset()
        ..start();
    }
    if (state.finished) _watch.stop();
    _progress.value = _SyncProgress(
        done: state.done,
        fraction: state.fraction,
        speed: state.speed,
        total: state.total,
        sentCount: state.sentCount,
        receivedCount: state.receivedCount,
        sentBytes: state.sentBytes,
        receivedBytes: state.receivedBytes,
        transferredBytes: state.transferredBytes,
        currentName: state.currentName.split('/').last,
        direction: state.currentName.isEmpty
            ? null
            : state.sending
                ? SyncDirection.push
                : SyncDirection.pull);
    setState(() {
      _running = !state.finished;
      _error = state.error;
      _result = state.finished
          ? SyncResult(
              pushed: state.sentCount,
              pulled: state.receivedCount,
              pushFailed: state.failed,
              pullFailed: 0)
          : null;
    });
  }

  Future<void> _start() async {
    try {
      final result = await widget.run!((done, total, current, direction) {
        if (!mounted) return;
        final p = _progress.value;
        final pushing = direction == SyncDirection.push;
        _progress.value = _SyncProgress(
          done: done,
          total: total,
          transferredBytes: _wireBytes,
          sentCount: p.sentCount + (pushing ? 1 : 0),
          receivedCount: p.receivedCount + (pushing ? 0 : 1),
          sentBytes: p.sentBytes + (pushing ? current.size : 0),
          receivedBytes: p.receivedBytes + (pushing ? 0 : current.size),
          currentName: current.relativePath.split('/').last,
          direction: direction,
          fraction: p.fraction,
          speed: p.speed,
        );
      }, (bytes) {
        _wireBytes += bytes;
        if (mounted && _watch.elapsedMilliseconds - _lastByteUpdate >= 100) {
          _lastByteUpdate = _watch.elapsedMilliseconds;
          _progress.value = _progress.value.withTransferredBytes(_wireBytes);
        }
      }, (details) {
        if (!mounted) return;
        final p = _progress.value;
        _progress.value = _SyncProgress(
            done: details.done,
            total: details.total,
            sentCount: p.sentCount,
            receivedCount: p.receivedCount,
            sentBytes: p.sentBytes,
            receivedBytes: p.receivedBytes,
            transferredBytes: _wireBytes,
            currentName: details.current.relativePath.split('/').last,
            direction: details.direction,
            fraction: details.fraction,
            speed: details.speed);
      });
      if (mounted) {
        setState(() {
          _running = false;
          _result = result;
        });
      }
    } catch (e) {
      if (e is TransferException && e.code == 'BUSY') {
        _busyRejected = true;
        if (_discardBusyDialog()) return;
      }
      if (mounted) {
        setState(() {
          _running = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final finished = !_running;
    final err = _error;
    final failed = _result?.failed ?? 0;
    final title = finished
        ? (err != null
            ? '同步失败'
            : failed > 0
                ? '同步完成（部分失败）'
                : '同步完成')
        : '${widget.remote?.value?.preparing == true ? '准备同步' : '同步中'} · ${widget.remote?.value?.mappingName ?? widget.mappingName}';

    return PopScope(
        canPop: finished,
        child: GlassDialog(
          title: title,
          maxWidth: 400,
          content: SizedBox(
            width: 360,
            child: err != null
                ? Text(
                    '同步失败，请重试。\n$err',
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: _danger),
                  )
                : ValueListenableBuilder<_SyncProgress>(
                    valueListenable: _progress,
                    builder: (context, p, _) {
                      final fraction = p.fraction ??
                          (p.total == 0
                              ? 0.0
                              : (p.done / p.total).clamp(0.0, 1.0).toDouble());
                      final seconds = _watch.elapsedMilliseconds / 1000.0;
                      final speed = p.speed ??
                          (seconds <= 0 ? 0.0 : p.transferredBytes / seconds);
                      final dirLabel = p.direction == SyncDirection.push
                          ? '发送'
                          : p.direction == SyncDirection.pull
                              ? '接收'
                              : '';
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.remote?.value != null) ...[
                            Text('来自「${widget.remote!.value!.peerName}」的同步',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, color: _muted)),
                            const SizedBox(height: 10),
                          ],
                          GlassProgressBar(
                            value: finished && err == null ? 1.0 : fraction,
                            height: 16,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '${(fraction * 100).toStringAsFixed(0)}% · '
                            '${p.done}/${p.total} 个文件',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '已发送 ${p.sentCount} · 已接收 ${p.receivedCount}',
                            style: const TextStyle(fontSize: 11, color: _muted),
                          ),
                          if (!finished && p.currentName.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              '当前：${dirLabel.isEmpty ? '' : '$dirLabel '}'
                              '${p.currentName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontSize: 11, color: _muted),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            '发送 ${formatBytes(p.sentBytes)} · '
                            '接收 ${formatBytes(p.receivedBytes)}',
                            style: const TextStyle(fontSize: 11, color: _muted),
                          ),
                          if (finished && failed > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              '$failed 个文件失败，请重新对比后重试',
                              style: const TextStyle(
                                  fontSize: 11, color: _warning),
                            ),
                          ],
                          if (finished && widget.failures.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            for (final f in widget.failures.take(3))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Text(
                                  '· $f',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 11, color: _danger),
                                ),
                              ),
                            if (widget.failures.length > 3)
                              Text(
                                '…等 ${widget.failures.length} 项',
                                style: const TextStyle(
                                    fontSize: 11, color: _danger),
                              ),
                          ],
                          if (!finished && speed > 0) ...[
                            const SizedBox(height: 2),
                            Text(
                              '速度 ${formatBytes(speed.round())}/s',
                              style:
                                  const TextStyle(fontSize: 11, color: _muted),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
          ),
          actions: [
            if (finished)
              FilledButton(
                child: const Text('关闭'),
                onPressed: () => Navigator.pop(
                    context,
                    widget.remote?.value?.task ??
                        (err == null ? _result : null)),
              ),
          ],
        ));
  }
}
