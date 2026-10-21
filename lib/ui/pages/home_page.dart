import 'dart:async';

import 'package:flutter/animation.dart' show AnimationController;
import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:flutter/widgets.dart'
    show
        AnimatedBuilder,
        SingleTickerProviderStateMixin,
        ValueListenableBuilder;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app_scope.dart';
import '../../core/utils.dart';
import '../../models/device_info.dart';
import '../../models/file_entry.dart';
import '../../models/sync_mapping.dart';
import '../../models/sync_plan.dart';
import '../../platform/permissions.dart';
import '../../services/local_index_service.dart';
import '../../services/sync_engine.dart';
import '../../services/transfer/receiver_client.dart';
import '../../services/transfer/sender_client.dart';
import '../widgets/glass.dart';

const _accent = Color(0xFF4A9EFF);
const _success = Color(0xFF7BE0A0);
const _danger = Color(0xFFFF9B9B);
const _warning = Color(0xFFFFC46B);
const _muted = Color(0xFF8A8A8A);
const _muted2 = Color(0xFF9A9A9A);

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  PeerDevice? _peer;
  final Map<String, SyncPlan> _plans = {};
  final Map<String, bool> _comparing = {};
  final Map<String, bool> _syncing = {};
  final Map<String, bool> _connecting = {};

  @override
  void initState() {
    super.initState();
    scope.addListener(_refresh);
    scope.config.addListener(_refresh);
  }

  @override
  void dispose() {
    scope.removeListener(_refresh);
    scope.config.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final devices = scope.discovery?.devices ?? const <PeerDevice>[];
    if (_peer != null) {
      var stillConnected = false;
      for (final d in devices) {
        if (d.id == _peer!.id && d.connected) {
          stillConnected = true;
          break;
        }
      }
      if (!stillConnected) _peer = null;
    }
    if (_peer == null) {
      for (final d in devices) {
        if (d.connected) {
          _peer = d;
          debugPrint('[MySend] 自动选定已连接设备: ${d.name}');
          break;
        }
      }
    }
    setState(() {});
  }

  void _toast(String msg, {InfoBarSeverity severity = InfoBarSeverity.info}) {
    if (!mounted) return;
    displayInfoBar(
      context,
      builder: (context, close) => InfoBar(
        severity: severity,
        title: Text(msg),
        action: IconButton(
          icon: const Icon(FluentIcons.chrome_close),
          onPressed: close,
        ),
      ),
    );
  }

  // ---- 连接 ----

  Future<void> _connect(PeerDevice d) async {
    if (_connecting[d.id] == true) return;
    setState(() => _connecting[d.id] = true);
    bool ok = false;
    try {
      if (isSender) {
        final c = SenderClient(address: d.address, port: d.port);
        ok = await c.sendPairRequest(scope.selfDescribe());
        c.close();
      } else {
        final c = ReceiverClient(address: d.address, port: d.port);
        ok = await c.sendPairRequest(scope.selfDescribe());
        c.close();
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _connecting[d.id] = false);
    if (ok) {
      final linked = d.copyWith(connected: true);
      scope.discovery?.addScanned(linked, connected: true);
      setState(() => _peer = linked);
      await _showConnectResult(linked, ok: true);
    } else {
      await _showConnectResult(d, ok: false);
    }
  }

  Future<void> _disconnect(PeerDevice d) async {
    scope.discovery?.markDisconnected(d.id);
    if (_peer?.id == d.id) {
      setState(() => _peer = null);
    }
    try {
      if (isSender) {
        final c = SenderClient(address: d.address, port: d.port);
        await c.disconnect(scope.selfDescribe());
        c.close();
      } else {
        final c = ReceiverClient(address: d.address, port: d.port);
        await c.disconnect(scope.selfDescribe());
        c.close();
      }
    } catch (_) {}
  }

  Future<bool> _checkFileAccess() async {
    if (!isAndroid) return true;
    final ok = await ensureFileAccess();
    if (!mounted) return ok;
    if (!ok) {
      _toast('未获得「所有文件访问」权限，无法读写目录',
          severity: InfoBarSeverity.error);
      await openManageStorageSettings();
    }
    return ok;
  }

  Future<void> _showConnectResult(PeerDevice d, {required bool ok}) {
    return showGlassDialog<void>(
      context: context,
      builder: (_) => _ConnectToast(d: d, ok: ok),
    );
  }

  // ---- 对比 & 同步 ----

  Future<void> _compare(SyncMapping m) async {
    final peer = _peer;
    if (peer == null) {
      _toast(isSender ? '请先连接一台接收设备' : '请先连接一台发送设备');
      return;
    }
    if (_comparing[m.id] == true) return;
    if (!await _checkFileAccess()) return;
    setState(() => _comparing[m.id] = true);
    try {
      final plan = isSender
          ? await _compareAsSender(m, peer)
          : await _compareAsReceiver(m, peer);
      if (mounted) setState(() => _plans[m.id] = plan);
      await _showCompareResult(m, plan);
    } catch (e) {
      _toast('「${m.name}」对比失败: $e', severity: InfoBarSeverity.error);
    } finally {
      if (mounted) setState(() => _comparing[m.id] = false);
    }
  }

  Future<SyncPlan> _compareAsSender(SyncMapping m, PeerDevice peer) async {
    final client = SenderClient(address: peer.address, port: peer.port);
    try {
      final dest = await client.getDestIndex(m.name);
      final destMap = {for (final e in dest) e.relativePath: e};
      final srcMap = await LocalIndexService.scan(m.sourcePath);
      return SyncEngine.computePlan(mapping: m, source: srcMap, dest: destMap);
    } finally {
      client.close();
    }
  }

  Future<SyncPlan> _compareAsReceiver(SyncMapping m, PeerDevice peer) async {
    final client = ReceiverClient(address: peer.address, port: peer.port);
    try {
      final src = await client.getIndex(m.name);
      final srcMap = {for (final e in src) e.relativePath: e};
      final destMap = await LocalIndexService.scan(m.destPath);
      return SyncEngine.computePlan(mapping: m, source: srcMap, dest: destMap);
    } finally {
      client.close();
    }
  }

  Future<void> _showCompareResult(SyncMapping m, SyncPlan plan) async {
    final names =
        plan.newOnly.map((e) => e.relativePath.split('/').last).toList();
    final accepted = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: '对比完成 · ${m.name}',
        maxWidth: 400,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              plan.isEmpty
                  ? '两端文件一致，无需同步。'
                  : '新增 ${names.length} 个文件 · ${formatBytes(plan.totalBytes)}',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            if (!plan.isEmpty) ...[
              const SizedBox(height: 10),
              for (final n in names.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '· $n',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _muted2),
                  ),
                ),
              if (names.length > 3)
                const Text('…', style: TextStyle(fontSize: 12, color: _muted2)),
            ],
          ],
        ),
        actions: [
          Button(
            child: const Text('关闭'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          if (!plan.isEmpty)
            FilledButton(
              child: const Text('同步'),
              onPressed: () => Navigator.pop(ctx, true),
            ),
        ],
      ),
    );
    if (accepted == true && mounted) await _sync(m);
  }

  Future<void> _sync(SyncMapping m) async {
    final peer = _peer;
    final plan = _plans[m.id];
    if (peer == null || plan == null || plan.isEmpty || (_syncing[m.id] ?? false)) {
      return;
    }
    if (!await _checkFileAccess()) return;
    setState(() => _syncing[m.id] = true);

    Future<int> runIt(
        void Function(int done, int total, FileEntry current) onProgress) async {
      final int failed;
      if (isSender) {
        final client = SenderClient(address: peer.address, port: peer.port);
        failed = await SyncEngine.push(
          mapping: m,
          client: client,
          files: plan.toSend,
          onProgress: onProgress,
        );
        await _persistSyncLog(
          failed: failed,
          plan: plan,
          mapping: m,
          push: (name, count, bytes, files) => client.sendSyncLog(
              name: name, fileCount: count, totalBytes: bytes, files: files),
        );
      } else {
        final client = ReceiverClient(address: peer.address, port: peer.port);
        failed = await SyncEngine.run(
          mapping: m,
          client: client,
          files: plan.toSend,
          onProgress: onProgress,
        );
        await _persistSyncLog(
          failed: failed,
          plan: plan,
          mapping: m,
          push: (name, count, bytes, files) => client.sendSyncLog(
              name: name, fileCount: count, totalBytes: bytes, files: files),
        );
      }
      return failed;
    }

    if (isAndroid) {
      try {
        await WakelockPlus.enable();
      } catch (_) {}
    }
    final failed = await showGlassDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SyncDialog(
        mappingName: m.name,
        totalBytes: plan.totalBytes,
        run: runIt,
      ),
    );
    if (isAndroid) {
      try {
        await WakelockPlus.disable();
      } catch (_) {}
    }

    if (failed != null && failed >= 0) {
      if (failed == 0 && mounted) {
        setState(() {
          _plans[m.id] = SyncPlan(
            mappingId: m.id,
            mappingName: m.name,
            toSend: const [],
            newOnly: const [],
          );
        });
      } else if (failed > 0) {
        _toast('$failed 个文件同步失败，请重新对比后重试',
            severity: InfoBarSeverity.warning);
      }
    }
    if (mounted) setState(() => _syncing[m.id] = false);
  }

  Future<void> _persistSyncLog({
    required int failed,
    required SyncPlan plan,
    required SyncMapping mapping,
    required Future<void> Function(
            String name, int count, int bytes, List<String> files)
        push,
  }) async {
    final successCount = plan.toSend.length - failed;
    if (successCount <= 0) return;
    final syncedNames =
        plan.toSend.map((e) => e.relativePath.split('/').last).toList();
    await scope.syncLog.add(
      name: mapping.name,
      fileCount: successCount,
      totalBytes: plan.totalBytes,
      files: syncedNames,
    );
    try {
      await push(mapping.name, successCount, plan.totalBytes, syncedNames);
    } catch (_) {}
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final cfg = scope.config.config;
    final devices = scope.discovery?.devices ?? const <PeerDevice>[];
    final mappings = cfg.mappings;
    final running = isSender
        ? (scope.server?.running ?? false)
        : (scope.receiverServer?.running ?? false);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
          children: [
            AppPageHeader(
              title: '状态',
              subtitle:
                  'MySend · ${isSender ? '电脑发送端' : '安卓接收端'} · 局域网单向同步',
            ),
            const SizedBox(height: 18),
            _localCard(
              cfg.deviceName,
              cfg.transferPort,
              mappings.length,
              running,
            ),
            const SizedBox(height: 22),
            SectionHeader(
              title: isSender ? '接收设备' : '发送设备',
              count: '${devices.length} 台',
            ),
            const SizedBox(height: 10),
            if (devices.isEmpty)
              const _SearchingIndicator()
            else
              for (final d in devices) _deviceCard(d),
            const SizedBox(height: 22),
            SectionHeader(title: '同步任务', count: '${mappings.length} 组'),
            const SizedBox(height: 10),
            if (mappings.isEmpty)
              const GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('尚未配置同步映射',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    SizedBox(height: 6),
                    Text(
                      '请先在「映射」页添加目录，并在另一端的同名映射中配置对应目录。',
                      style: TextStyle(
                          fontSize: 12, height: 1.5, color: _muted2),
                    ),
                  ],
                ),
              )
            else
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (var i = 0; i < mappings.length; i++) ...[
                      if (i > 0)
                        Container(height: 1, color: const Color(0x1FFFFFFF)),
                      _mappingItem(mappings[i]),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _localCard(String deviceName, int port, int mappingCount, bool running) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: _accent.withAlpha(38),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(_formIcon(deviceForm), size: 24, color: _accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deviceName,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${isSender ? '发送端' : '接收端'} · ${_formLabel(deviceForm)}',
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                  ],
                ),
              ),
              StatusPill(
                label: running ? '在线' : '未启动',
                color: running ? _success : _danger,
              ),
            ],
          ),
          const SizedBox(height: 14),
          InfoRow(label: '服务端口', value: '$port'),
          InfoRow(label: '映射数量', value: '$mappingCount'),
          InfoRow(
            label: '设备标识',
            value: scope.config.config.deviceId.length > 8
                ? scope.config.config.deviceId.substring(0, 8)
                : scope.config.config.deviceId,
          ),
          const SizedBox(height: 10),
          const Text(
            '请确保电脑与手机连接同一 Wi-Fi，或让电脑连接手机热点。'
            '任一端都可以发起对比与同步。',
            style: TextStyle(fontSize: 12, height: 1.5, color: _muted2),
          ),
        ],
      ),
    );
  }

  Widget _deviceCard(PeerDevice d) {
    final connected = d.connected || _peer?.id == d.id;
    final busy = _connecting[d.id] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _accent.withAlpha(30),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_formIcon(d.form), size: 22, color: _accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (connected) ...[
                        const SizedBox(width: 8),
                        const StatusPill(label: '已连接', color: _accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    connected ? '可发起对比与同步' : '同一局域网 · 点击连接',
                    style: TextStyle(
                      fontSize: 11,
                      color: connected ? _success : _muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: ProgressRing(strokeWidth: 2),
              )
            else
              Button(
                onPressed: () => connected ? _disconnect(d) : _connect(d),
                child: Text(
                  connected ? '断开' : '连接',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _mappingItem(SyncMapping m) {
    final plan = _plans[m.id];
    final comparing = _comparing[m.id] == true;
    final syncing = _syncing[m.id] == true;
    final connected = _peer != null;
    final path = isSender ? m.sourcePath : m.destPath;

    final String status;
    final Color statusColor;
    if (comparing) {
      status = '对比中…';
      statusColor = _warning;
    } else if (syncing) {
      status = '同步中…';
      statusColor = _warning;
    } else if (plan == null) {
      status = connected ? '未对比' : '未连接';
      statusColor = _muted;
    } else if (plan.isEmpty) {
      status = '已一致';
      statusColor = _success;
    } else {
      status = '新增 ${plan.newOnly.length} 个';
      statusColor = _accent;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.folder, size: 18, color: _accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name, style: const TextStyle(fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(
                      path.isEmpty ? '未填写目录' : path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusPill(label: status, color: statusColor),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (plan != null && !plan.isEmpty)
                Text(
                  formatBytes(plan.totalBytes),
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              const Spacer(),
              Button(
                onPressed: connected && !comparing && !syncing
                    ? () => _compare(m)
                    : null,
                child: Text(
                  comparing ? '对比中…' : '对比',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: connected &&
                        !comparing &&
                        !syncing &&
                        plan != null &&
                        !plan.isEmpty
                    ? () => _sync(m)
                    : null,
                child: Text(
                  syncing ? '同步中…' : '同步',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static IconData _formIcon(String form) {
    switch (form) {
      case 'desktop':
        return FluentIcons.t_v_monitor;
      case 'tablet':
        return FluentIcons.tablet;
      case 'phone':
        return FluentIcons.cell_phone;
      default:
        return FluentIcons.devices2;
    }
  }

  static String _formLabel(String form) {
    switch (form) {
      case 'desktop':
        return '电脑';
      case 'tablet':
        return '平板';
      case 'phone':
        return '手机';
      default:
        return '设备';
    }
  }
}

/// 搜索设备时的呼吸扩散动画。
class _SearchingIndicator extends StatefulWidget {
  const _SearchingIndicator();

  @override
  State<_SearchingIndicator> createState() => _SearchingIndicatorState();
}

class _SearchingIndicatorState extends State<_SearchingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Row(
        children: [
          SizedBox(
            width: 52,
            height: 52,
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      for (var i = 0; i < 3; i++)
                        _ring((_controller.value + i / 3) % 1.0),
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: _accent.withAlpha(38),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(FluentIcons.wifi,
                            size: 16, color: _accent),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '正在搜索同一局域网内的设备…',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                SizedBox(height: 3),
                Text(
                  '请确保电脑与手机连接同一 Wi-Fi，或让电脑连接手机热点。',
                  style:
                      TextStyle(fontSize: 11, height: 1.4, color: _muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _ring(double t) {
    return Opacity(
      opacity: ((1 - t) * 0.5).clamp(0.0, 1.0).toDouble(),
      child: Transform.scale(
        scale: 0.55 + t * 0.8,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _accent, width: 1.2),
          ),
        ),
      ),
    );
  }
}

class _SyncProgress {
  final int done;
  final int total;
  final int sentBytes;
  final String currentName;

  const _SyncProgress({
    this.done = 0,
    this.total = 0,
    this.sentBytes = 0,
    this.currentName = '',
  });
}

/// 同步进度弹窗：平滑进度条 + 文件计数 + 当前文件 + 速度，完成后需手动关闭。
class _SyncDialog extends StatefulWidget {
  final String mappingName;
  final int totalBytes;
  final Future<int> Function(
      void Function(int done, int total, FileEntry current)) run;

  const _SyncDialog({
    required this.mappingName,
    required this.totalBytes,
    required this.run,
  });

  @override
  State<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<_SyncDialog> {
  final ValueNotifier<_SyncProgress> _progress =
      ValueNotifier(const _SyncProgress());
  bool _running = true;
  String? _error;
  int _failed = 0;
  final Stopwatch _watch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _watch.start();
    _start();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      _failed = await widget.run((done, total, current) {
        if (!mounted) return;
        final p = _progress.value;
        _progress.value = _SyncProgress(
          done: done,
          total: total,
          sentBytes: p.sentBytes + current.size,
          currentName: current.relativePath.split('/').last,
        );
      });
      if (mounted) setState(() => _running = false);
    } catch (e) {
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
    final title = finished
        ? (err != null
            ? '同步失败'
            : _failed > 0
                ? '同步完成（部分失败）'
                : '同步完成')
        : '同步中 · ${widget.mappingName}';

    return GlassDialog(
      title: title,
      maxWidth: 400,
      content: SizedBox(
        width: 360,
        child: err != null
            ? Text(
                '同步失败，请重试。\n$err',
                style: const TextStyle(fontSize: 13, color: _danger),
              )
            : ValueListenableBuilder<_SyncProgress>(
                valueListenable: _progress,
                builder: (context, p, _) {
                  final fraction = p.total == 0
                      ? 0.0
                      : (p.done / p.total).clamp(0.0, 1.0).toDouble();
                  final seconds = _watch.elapsedMilliseconds / 1000.0;
                  final speed = seconds <= 0 ? 0.0 : p.sentBytes / seconds;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                      if (!finished && p.currentName.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          '当前：${p.currentName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: _muted),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        '已传输 ${formatBytes(p.sentBytes)} / '
                        '${formatBytes(widget.totalBytes)}',
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                      if (finished && _failed > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          '$_failed 个文件失败，请重新对比后重试',
                          style: const TextStyle(fontSize: 11, color: _warning),
                        ),
                      ],
                      if (!finished && speed > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          '速度 ${formatBytes(speed.round())}/s',
                          style: const TextStyle(fontSize: 11, color: _muted),
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
            onPressed: () => Navigator.pop(context, err == null ? _failed : -1),
          ),
      ],
    );
  }
}

/// 连接状态自动提示：无按钮，约 1.3 秒后自动关闭，不显示 IP。
class _ConnectToast extends StatefulWidget {
  final PeerDevice d;
  final bool ok;

  const _ConnectToast({required this.d, required this.ok});

  @override
  State<_ConnectToast> createState() => _ConnectToastState();
}

class _ConnectToastState extends State<_ConnectToast> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1300), () {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.ok ? _success : _danger;
    return GlassDialog(
      title: widget.ok ? '已连接' : '连接失败',
      maxWidth: 300,
      content: Row(
        children: [
          Icon(
            widget.ok ? FluentIcons.check_mark : FluentIcons.error,
            size: 20,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '「${widget.d.name}」${widget.ok ? '连接成功' : '连接失败'}',
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
