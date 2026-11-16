import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:fluent_ui/fluent_ui.dart';

import '../../models/remote_sync_state.dart';
import 'glass.dart';
import 'sync_dialog.dart';

/// 挂在根页面，保证切换到映射或设置页时仍能展示对端同步。
class RemoteSyncDialogHost extends StatefulWidget {
  final ValueListenable<RemoteSyncState?> progress;
  final Widget child;

  const RemoteSyncDialogHost(
      {super.key, required this.progress, required this.child});

  @override
  State<RemoteSyncDialogHost> createState() => _RemoteSyncDialogHostState();
}

class _RemoteSyncDialogHostState extends State<RemoteSyncDialogHost> {
  bool _showing = false;
  bool _scheduled = false;
  String? _dismissedTask;

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(RemoteSyncDialogHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_changed);
      widget.progress.addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    widget.progress.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final state = widget.progress.value;
    if (!mounted ||
        state == null ||
        state.task == _dismissedTask ||
        _showing ||
        _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scheduled = false;
      final current = widget.progress.value;
      if (!mounted ||
          current == null ||
          current.task == _dismissedTask ||
          _showing) return;
      _showing = true;
      // 新任务到来时复用已经打开的弹窗，避免结果未关闭就层层叠加。
      final dismissed = await showGlassDialog<Object>(
          context: context,
          barrierDismissible: false,
          builder: (_) => SyncDialog.remote(remote: widget.progress));
      _showing = false;
      if (!mounted) return;
      if (dismissed is String) _dismissedTask = dismissed;
      _changed();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
