import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:flutter/widgets.dart'
    show ValueListenableBuilder, TweenAnimationBuilder;
import 'package:flutter/animation.dart' show Curves, Tween;
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
import '../widgets/qr_widgets.dart';

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
    // 被动接受配对时（对端发起连接，本端自动接受并标记对方 connected），
    // 本端 _peer 尚未设置；这里自动选定已连接的设备，使双方都能发起对比/同步。
    if (_peer == null) {
      for (final d in scope.discovery?.devices ?? const <PeerDevice>[]) {
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

  /// 断开与指定设备的连接：从发现列表移除，并清空当前选中设备。
  void _disconnect(PeerDevice d) {
    scope.discovery?.removeDevice(d.id);
    if (_peer?.id == d.id) {
      setState(() => _peer = null);
    }
  }

  /// Android 端确保「所有文件访问」权限（读写真实目录依赖）。
  /// 未授权时提示并引导到系统设置开启，返回是否已就绪。
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

  /// 连接状态提示窗：居中蓝底玻璃、无按钮，短暂显示后自动消失（成功/失败两种）。
  Future<void> _showConnectResult(PeerDevice d, {required bool ok}) async {
    await showGlassDialog<Object?>(
      context: context,
      builder: (_) => _ConnectToast(d: d, ok: ok),
    );
  }

  /// 手机端扫码添加设备并立即发起连接。
  /// 先判断两端是否同一局域网：同网段则直接连接；异网则走「热点组网」教程。
  Future<void> _scanPair() async {
    final parsed = await Navigator.push<Map<String, dynamic>>(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const QrScannerPage(),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
      ),
    );
    if (parsed == null || !mounted) return;
    final ip = parsed['ip'] as String? ?? '';
    if (ip.isEmpty) return;
    final peer = PeerDevice.fromEnvelope(parsed, ip);

    final sameLan = await inSameLan(ip);
    if (!mounted) return;
    if (sameLan) {
      scope.discovery?.addScanned(peer);
      setState(() => _peer = peer);
      await _connect(peer);
    } else {
      await _hotspotPair();
    }
  }

  /// 热点组网：仅展示一份手动组网教程，不做自动判定，用户自行操作后回到本页连接。
  Future<void> _hotspotPair() async {
    await showGlassDialog(
      context: context,
      builder: (_) => const _HotspotTutorialDialog(),
    );
  }

  /// 电脑端展示连接二维码。
  Future<void> _showPairQr() async {
    await showGlassDialog(
      context: context,
      builder: (_) => const QrPairDialog(),
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
      final plan = isSender ? await _compareAsSender(m, peer) : await _compareAsReceiver(m, peer);
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
    final names = plan.newOnly.map((e) => e.relativePath.split('/').last).toList();
    await showGlassDialog(
      context: context,
      builder: (ctx) => GlassDialog(
        title: '对比完成 · ${m.name}',
        maxWidth: 400,
        content: SizedBox(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '新增 ${names.length} 个文件',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              if (names.isEmpty)
                const Text('没有新增文件，两端已一致。',
                    style: TextStyle(color: Color(0xFFc0c0c0)))
              else ...[
                ...names
                    .take(3)
                    .map((n) => Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            '· $n',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )),
                if (names.length > 3)
                  const Text('…', style: TextStyle(color: Color(0xFFc0c0c0))),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            child: const Text('确定'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
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
      // 日志已在 runIt（最后一个文件传完时）通过 _persistSyncLog 记录并推送给对端。
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

  /// 在最后一个文件传输完成后，立即本地记录本次同步日志并推送给对端，
  /// 让双方各自留存该次同步任务记录（不依赖同步弹窗是否已点关闭）。
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
    } catch (_) {
      // 对端离线或推送失败时不影响本端日志记录。
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final cfg = scope.config.config;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _sectionTitle('本机'),
            _card(_deviceCard(cfg.deviceName, cfg.transferPort)),
            const SizedBox(height: 12),
            _card(const _LanHint()),
            const SizedBox(height: 24),
            _sectionTitle(isSender ? '已发现的接收设备' : '可用的发送设备'),
            for (final d in scope.discovery?.devices ?? const <PeerDevice>[])
              _deviceRow(d),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: isSender
                  ? FilledButton(
                      child: const Text('创建连接二维码'),
                      onPressed: _showPairQr,
                    )
                  : FilledButton(
                      child: const Text('扫码添加设备'),
                      onPressed: _scanPair,
                    ),
            ),
            const SizedBox(height: 24),
            _sectionTitle('同步任务'),
            if (cfg.mappings.isEmpty)
              const Text('尚未配置映射，请到「映射」页添加。')
            else if (_peer == null)
              const Text('请先连接一台设备，再进行对比与同步。')
            else
              for (final m in cfg.mappings) _mappingRow(m),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(t,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      );

  Widget _card(Widget child) => GlassCard(child: child);

  Widget _deviceCard(String deviceName, int transferPort) {
    final running = isSender ? (scope.server?.running ?? false) : (scope.receiverServer?.running ?? false);
    return Row(
      children: [
        Icon(_formIcon(deviceForm), size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(deviceName,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '${isSender ? '发送端' : '接收端'} · ${_formLabel(deviceForm)}'
                ' · 端口 $transferPort${running ? ' · 服务运行中' : ''}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9a9a9a)),
              ),
            ],
          ),
        ),
        Icon(
          running ? FluentIcons.completed : FluentIcons.warning,
          size: 20,
        ),
      ],
    );
  }

  Widget _deviceRow(PeerDevice d) {
    final isLinking = _connecting[d.id] ?? false;
    final connected = d.connected || _peer?.id == d.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _card(
        Row(
          children: [
            Icon(_formIcon(d.form), size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(d.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      if (connected) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0x334A9EFF),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('已连接',
                              style: TextStyle(fontSize: 11, color: Color(0xFF4A9EFF))),
                        ),
                      ],
                    ],
                  ),
                  Text('${_formLabel(d.form)} · ${d.address}:${d.port}',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF9a9a9a))),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              child: Text(isLinking ? '连接中…' : (connected ? '断开' : '连接')),
              onPressed: isLinking
                  ? null
                  : (connected ? () => _disconnect(d) : () => _connect(d)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mappingRow(SyncMapping m) {
    final plan = _plans[m.id];
    final comparing = _comparing[m.id] ?? false;
    final syncing = _syncing[m.id] ?? false;

    String status;
    if (syncing) {
      status = '同步中…';
    } else if (plan == null) {
      status = '未对比';
    } else if (plan.isEmpty) {
      status = '已一致，无需同步';
    } else {
      status = '新增 ${plan.newOnly.length} 个';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _card(
        Row(
          children: [
            const Icon(FluentIcons.folder, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                m.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 12, color: Color(0xFFc0c0c0)),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              child: Text(comparing ? '对比中…' : '对比'),
              onPressed: (comparing || syncing) ? null : () => _compare(m),
            ),
            const SizedBox(width: 8),
            Button(
              child: Text(syncing ? '同步中…' : '同步'),
              onPressed: (syncing || plan == null || plan.isEmpty)
                  ? null
                  : () => _sync(m),
            ),
          ],
        ),
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

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 局域网依赖提示条。
class _LanHint extends StatelessWidget {
  const _LanHint();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Icon(FluentIcons.wifi, size: 20, color: Color(0xFF4A9EFF)),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            '应用功能依赖局域网：请确保电脑与手机连接同一 Wi-Fi / 路由器。',
            style: TextStyle(fontSize: 13, color: Color(0xFFc0c0c0)),
          ),
        ),
      ],
    );
  }
}

/// 同步进度弹窗：进度条 + 文件名 / 数量 / 大小 / 速度，失败原因 / 成功手动关闭。
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

/// 同步进度快照，用 [ValueNotifier] 承载，进度更新只重绘进度行，
/// 避免每次进度都重建整个玻璃弹窗（含 BackdropFilter 模糊），
/// 从根上消除「进度弹窗高频重绘模糊导致同步卡住」的问题。
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

class _SyncDialogState extends State<_SyncDialog> {
  final ValueNotifier<_SyncProgress> _progress = ValueNotifier(const _SyncProgress());
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
      if (mounted) setState(() {
        _running = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final finished = !_running;
    final err = _error;

    return GlassDialog(
      title: finished
          ? (err != null ? '同步失败' : '同步完成')
          : '同步中 · ${widget.mappingName}',
      maxWidth: 400,
      content: SizedBox(
        width: 360,
        child: err != null
            ? Text('同步失败，请重试。\n$err',
                style: const TextStyle(fontSize: 13, color: Color(0xFFE9AA7E)))
            : ValueListenableBuilder<_SyncProgress>(
                valueListenable: _progress,
                builder: (context, p, _) {
                  final progress = p.total == 0
                      ? 0.0
                      : (p.done / p.total).clamp(0.0, 1.0);
                  final seconds = _watch.elapsedMilliseconds / 1000.0;
                  final speed = seconds <= 0 ? 0 : (p.sentBytes / seconds);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        height: 18,
                        child: LayoutBuilder(
                          builder: (context, c) {
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(9),
                              child: Container(
                                width: c.maxWidth,
                                height: 18,
                                color: const Color(0x1AFFFFFF),
                                alignment: Alignment.centerLeft,
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween<double>(end: progress),
                                  duration: const Duration(milliseconds: 400),
                                  curve: Curves.easeOutCubic,
                                  builder: (_, v, __) => Container(
                                    width: c.maxWidth * v.clamp(0.0, 1.0),
                                    height: 18,
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Color(0xFF4A9EFF),
                                          Color(0xFF7C5CFF),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                          '${(progress * 100).toStringAsFixed(0)}%   ${p.done} / ${p.total} 个文件',
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFFe0e0e0))),
                      if (p.currentName.isNotEmpty && !finished) ...[
                        const SizedBox(height: 4),
                        Text('当前：${p.currentName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF9a9a9a))),
                      ],
                      const SizedBox(height: 4),
                      Text(
                          '已传输 ${_fmtBytes(p.sentBytes)} / ${_fmtBytes(widget.totalBytes)}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF9a9a9a))),
                      if (finished && _failed > 0) ...[
                        const SizedBox(height: 4),
                        Text('$_failed 个文件失败，请重新对比后重试',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFFE9AA7E))),
                      ],
                      if (!finished && speed > 0) ...[
                        const SizedBox(height: 2),
                        Text('速度 ${_fmtBytes(speed.round())}/s',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF9a9a9a))),
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

/// 连接状态自动提示：无按钮，约 2.2 秒后自动关闭。
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
    _timer = Timer(const Duration(milliseconds: 1200), () {
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
    final ok = widget.ok;
    final d = widget.d;
    return GlassDialog(
      title: ok ? '已连接' : '连接失败',
      content: SizedBox(
        width: 260,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ok ? '已连接「${d.name}」' : '无法连接「${d.name}」',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: ok ? null : const Color(0xFFE9AA7E),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              ok
                  ? '${d.address}:${d.port}'
                  : '请检查设备是否在线、网络是否连通后重试。',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9a9a9a)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 热点组网教程弹窗：仅给出一份手动组网步骤提示，不做任何连接判定。
class _HotspotTutorialDialog extends StatelessWidget {
  const _HotspotTutorialDialog();

  @override
  Widget build(BuildContext context) {
    return GlassDialog(
      title: '热点组网教程',
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('当前手机与电脑不在同一网络，请手动组网：',
                style: TextStyle(fontSize: 13, color: Color(0xFFc0c0c0))),
            SizedBox(height: 12),
            Text('1. 进入手机「设置 → 便携式热点」，开启热点；',
                style: TextStyle(fontSize: 13)),
            SizedBox(height: 4),
            Text('2. 在电脑右下角 Wi-Fi 列表连接该热点（密码见手机热点页）；',
                style: TextStyle(fontSize: 13)),
            SizedBox(height: 4),
            Text('3. 回到本页，电脑会自动被发现，再点「连接」继续。',
                style: TextStyle(fontSize: 13)),
          ],
        ),
      ),
      actions: [
        FilledButton(
          child: const Text('知道了'),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}