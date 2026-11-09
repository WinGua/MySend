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
import '../../services/transfer/protocol.dart';
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
  final Map<String, String> _planSignatures = {};

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
    // 映射被删除或路径被修改后，旧对比结果不再可信。
    final mappings = scope.config.config.mappings;
    final validIds = {for (final m in mappings) m.id};
    _plans.removeWhere((id, _) => !validIds.contains(id));
    _planSignatures.removeWhere((id, _) => !validIds.contains(id));
    for (final m in mappings) {
      final sig = '${m.sourcePath}|${m.destPath}';
      final prev = _planSignatures[m.id];
      if (prev != null && prev != sig) _plans.remove(m.id);
      _planSignatures[m.id] = sig;
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
    final ok = await scope.connect(d);
    if (!mounted) return;
    setState(() => _connecting[d.id] = false);
    if (ok) {
      final linked = (scope.discovery?.devices ?? const <PeerDevice>[])
          .firstWhere((e) => e.id == d.id, orElse: () => d.copyWith(connected: true));
      setState(() => _peer = linked);
      await _showConnectResult(linked, ok: true);
    } else {
      await _showConnectResult(d, ok: false);
    }
  }

  Future<void> _disconnect(PeerDevice d) async {
    if (_peer?.id == d.id) {
      setState(() => _peer = null);
    }
    await scope.disconnect(d);
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
      _toast('请先连接一台设备');
      return;
    }
    if (_comparing[m.id] == true) return;
    if (m.localRoot(isSender).isEmpty) {
      _toast('「${m.name}」尚未选择本机目录，请先在映射页设置');
      return;
    }
    if (!await _checkFileAccess()) return;
    setState(() => _comparing[m.id] = true);
    try {
      final plan = await _compareWith(m, peer);
      if (mounted) setState(() => _plans[m.id] = plan);
      await _showCompareResult(m, plan);
    } catch (e) {
      _toast('「${m.name}」对比失败: $e', severity: InfoBarSeverity.error);
    } finally {
      if (mounted) setState(() => _comparing[m.id] = false);
    }
  }

  /// 同时扫描本机与对端，计算双向新增文件。
  Future<SyncPlan> _compareWith(SyncMapping m, PeerDevice peer) async {
    final client = scope.clientFor(peer);
    try {
      final remote = await client.fetchIndex(m.name);
      final remoteMap = {for (final e in remote) e.relativePath: e};
      final localMap = await LocalIndexService.scan(m.localRoot(isSender));
      return SyncEngine.computeBidirectionalPlan(
        mapping: m,
        local: localMap,
        remote: remoteMap,
      );
    } finally {
      client.close();
    }
  }

  Future<void> _showCompareResult(SyncMapping m, SyncPlan plan) async {
    final sentNames =
        plan.toPush.map((e) => e.relativePath.split('/').last).toList();
    final receivedNames =
        plan.toPull.map((e) => e.relativePath.split('/').last).toList();
    final accepted = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: '对比完成 · ${m.name}',
        maxWidth: 420,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              plan.isEmpty
                  ? '两端文件一致，无需同步。'
                  : '共 ${plan.totalCount} 个新增文件 · '
                      '${formatBytes(plan.totalBytes)}',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            if (plan.toPush.isNotEmpty) ...[
              const SizedBox(height: 10),
              _planGroup(
                '将发送 ${plan.toPush.length} 个 · '
                '${formatBytes(plan.pushBytes)}',
                sentNames,
              ),
            ],
            if (plan.toPull.isNotEmpty) ...[
              const SizedBox(height: 10),
              _planGroup(
                '将接收 ${plan.toPull.length} 个 · '
                '${formatBytes(plan.pullBytes)}',
                receivedNames,
              ),
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

  Widget _planGroup(String title, List<String> names) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 4),
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
    );
  }

  Future<void> _sync(SyncMapping m) async {
    final peer = _peer;
    final plan = _plans[m.id];
    if (peer == null ||
        plan == null ||
        plan.isEmpty ||
        (_syncing[m.id] ?? false)) {
      return;
    }
    // 同一时刻只允许一个同步任务，避免并发写入互相干扰。
    if (_syncing.values.any((v) => v)) {
      _toast('已有同步任务在进行，请等待完成');
      return;
    }
    if (!await _checkFileAccess()) return;
    setState(() => _syncing[m.id] = true);

    // 记录成功文件与失败原因，供日志和结果弹窗使用。
    final failures = <String>[];
    final sentNames = <String>[];
    final receivedNames = <String>[];
    var sentBytes = 0;
    var receivedBytes = 0;

    Future<SyncResult> runIt(
      void Function(int done, int total, FileEntry current, SyncDirection dir)
          onProgress,
    ) async {
      final client = scope.clientFor(peer);
      final localServer = scope.transferServer;
      localServer?.busy = true;
      try {
        final result = await SyncEngine.runBidirectional(
          mapping: m,
          client: client,
          plan: plan,
          localRoot: m.localRoot(isSender),
          onProgress: (done, total, current, direction) {
            if (direction == SyncDirection.push) {
              sentNames.add(current.relativePath.split('/').last);
              sentBytes += current.size;
            } else {
              receivedNames.add(current.relativePath.split('/').last);
              receivedBytes += current.size;
            }
            onProgress(done, total, current, direction);
          },
          onFailure: (entry, direction, error) {
            if (failures.length < 20) {
              failures.add(
                '${direction == SyncDirection.push ? '发送' : '接收'} '
                '${entry.relativePath}：$error',
              );
            }
          },
        );
        await _persistSyncLog(
          peerName: peer.name,
          mappingName: m.name,
          sentNames: sentNames,
          sentBytes: sentBytes,
          receivedNames: receivedNames,
          receivedBytes: receivedBytes,
          push: client.sendLog,
        );
        return result;
      } finally {
        localServer?.busy = false;
        client.close();
      }
    }

    if (isAndroid) {
      try {
        await WakelockPlus.enable();
      } catch (_) {}
    }
    final result = await showGlassDialog<SyncResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SyncDialog(
        mappingName: m.name,
        failures: failures,
        run: runIt,
      ),
    );
    if (isAndroid) {
      try {
        await WakelockPlus.disable();
      } catch (_) {}
    }

    if (result != null) {
      if (result.success) {
        if (mounted) {
          setState(() {
            _plans[m.id] = SyncPlan(
              mappingId: m.id,
              mappingName: m.name,
              toPush: const [],
              toPull: const [],
              skippedCount: plan.skippedCount + plan.totalCount,
            );
          });
        }
      } else {
        _toast('${result.failed} 个文件同步失败，请重新对比后重试',
            severity: InfoBarSeverity.warning);
      }
    }
    if (mounted) setState(() => _syncing[m.id] = false);
  }

  Future<void> _persistSyncLog({
    required String peerName,
    required String mappingName,
    required List<String> sentNames,
    required int sentBytes,
    required List<String> receivedNames,
    required int receivedBytes,
    required Future<void> Function(SyncLogReport report) push,
  }) async {
    if (sentNames.isEmpty && receivedNames.isEmpty) return;
    final report = SyncLogReport(
      mappingName: mappingName,
      peerName: peerName,
      time: DateTime.now(),
      sentCount: sentNames.length,
      sentBytes: sentBytes,
      sentFiles: sentNames,
      receivedCount: receivedNames.length,
      receivedBytes: receivedBytes,
      receivedFiles: receivedNames,
    );
    await scope.syncLog.add(
      name: report.mappingName,
      time: report.time,
      peerName: report.peerName,
      sentCount: report.sentCount,
      sentBytes: report.sentBytes,
      sentFiles: report.sentFiles,
      receivedCount: report.receivedCount,
      receivedBytes: report.receivedBytes,
      receivedFiles: report.receivedFiles,
    );
    try {
      // 推送给对端的日志要带上本机设备名，对端据此显示「对端」名称。
      await push(SyncLogReport(
        mappingName: report.mappingName,
        peerName: scope.config.config.deviceName,
        time: report.time,
        sentCount: report.sentCount,
        sentBytes: report.sentBytes,
        sentFiles: report.sentFiles,
        receivedCount: report.receivedCount,
        receivedBytes: report.receivedBytes,
        receivedFiles: report.receivedFiles,
      ));
    } catch (_) {}
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final cfg = scope.config.config;
    final devices = scope.discovery?.devices ?? const <PeerDevice>[];
    final mappings = cfg.mappings;
    final running = scope.server?.running ?? false;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
          children: [
            AppPageHeader(
              title: '状态',
              subtitle:
                  'MySend · ${isSender ? '电脑端' : '安卓端'} · 局域网双向同步',
            ),
            const SizedBox(height: 18),
            _localCard(
              cfg.deviceName,
              scope.localPort,
              mappings.length,
              running,
            ),
            const SizedBox(height: 22),
            SectionHeader(
              title: '可连接设备',
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
                      '${isSender ? '电脑端' : '安卓端'} · ${_formLabel(deviceForm)}',
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
            '任一端点击同步即可双向互补新增。',
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
    final anySyncing = _syncing.values.any((v) => v);
    final connected = _peer != null;
    final path = m.localRoot(isSender);

    final String status;
    final Color statusColor;
    if (comparing) {
      status = '对比中…';
      statusColor = _warning;
    } else if (syncing) {
      status = '同步中…';
      statusColor = _warning;
    } else if (!connected) {
      status = '未连接';
      statusColor = _muted;
    } else if (plan == null) {
      status = '未对比';
      statusColor = _muted;
    } else if (plan.isEmpty) {
      status = '已一致';
      statusColor = _success;
    } else {
      final parts = <String>[];
      if (plan.toPush.isNotEmpty) parts.add('发送 ${plan.toPush.length}');
      if (plan.toPull.isNotEmpty) parts.add('接收 ${plan.toPull.length}');
      status = parts.join(' · ');
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
                  [
                    if (plan.toPush.isNotEmpty)
                      '发送 ${formatBytes(plan.pushBytes)}',
                    if (plan.toPull.isNotEmpty)
                      '接收 ${formatBytes(plan.pullBytes)}',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              const Spacer(),
              Button(
                onPressed: connected && !comparing && !syncing && !anySyncing
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
                        !anySyncing &&
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
  final int sentCount;
  final int receivedCount;
  final int sentBytes;
  final int receivedBytes;
  final String currentName;
  final SyncDirection? direction;

  const _SyncProgress({
    this.done = 0,
    this.total = 0,
    this.sentCount = 0,
    this.receivedCount = 0,
    this.sentBytes = 0,
    this.receivedBytes = 0,
    this.currentName = '',
    this.direction,
  });

  int get totalBytes => sentBytes + receivedBytes;
}

/// 同步进度弹窗：总进度 + 发送/接收分项 + 当前文件 + 速度，完成后需手动关闭。
class _SyncDialog extends StatefulWidget {
  final String mappingName;

  /// 同步过程中收集到的失败原因（最多 20 条），由调用方持有。
  final List<String> failures;
  final Future<SyncResult> Function(
    void Function(int done, int total, FileEntry current, SyncDirection dir)
        onProgress,
  ) run;

  const _SyncDialog({
    required this.mappingName,
    required this.failures,
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
  SyncResult? _result;
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
      final result = await widget.run((done, total, current, direction) {
        if (!mounted) return;
        final p = _progress.value;
        final pushing = direction == SyncDirection.push;
        _progress.value = _SyncProgress(
          done: done,
          total: total,
          sentCount: p.sentCount + (pushing ? 1 : 0),
          receivedCount: p.receivedCount + (pushing ? 0 : 1),
          sentBytes: p.sentBytes + (pushing ? current.size : 0),
          receivedBytes: p.receivedBytes + (pushing ? 0 : current.size),
          currentName: current.relativePath.split('/').last,
          direction: direction,
        );
      });
      if (mounted) {
        setState(() {
          _running = false;
          _result = result;
        });
      }
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
    final failed = _result?.failed ?? 0;
    final title = finished
        ? (err != null
            ? '同步失败'
            : failed > 0
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
                  final speed = seconds <= 0 ? 0.0 : p.totalBytes / seconds;
                  final dirLabel = p.direction == SyncDirection.push
                      ? '发送'
                      : p.direction == SyncDirection.pull
                          ? '接收'
                          : '';
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
                          style: const TextStyle(fontSize: 11, color: _muted),
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
                          style: const TextStyle(fontSize: 11, color: _warning),
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
                              style:
                                  const TextStyle(fontSize: 11, color: _danger),
                            ),
                          ),
                        if (widget.failures.length > 3)
                          Text(
                            '…等 ${widget.failures.length} 项',
                            style: const TextStyle(fontSize: 11, color: _danger),
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
            onPressed: () =>
                Navigator.pop(context, err == null ? _result : null),
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
