import 'package:fluent_ui/fluent_ui.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app_scope.dart';
import '../../core/utils.dart';
import '../../models/device_info.dart';
import '../../models/sync_mapping.dart';
import '../../models/sync_plan.dart';
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
    if (mounted) setState(() {});
  }

  void _toast(String msg, {InfoBarSeverity severity = InfoBarSeverity.info}) {
    if (!mounted) return;
    displayInfoBar(
      context,
      builder: (context, close) => InfoBar(
        severity: severity,
        title: Text(msg),
        action: IconButton(
          icon: const Icon(FluentIcons.dismiss),
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
      ok = isSender
          ? await SenderClient(address: d.address, port: d.port)
              .sendPairRequest(scope.selfDescribe())
          : await ReceiverClient(address: d.address, port: d.port)
              .sendPairRequest(scope.selfDescribe());
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _connecting[d.id] = false);
    if (ok) {
      final linked = d.copyWith(connected: true);
      scope.discovery?.addScanned(linked, connected: true);
      setState(() => _peer = linked);
      _toast('已连接「${d.name}」');
    } else {
      _toast('连接「${d.name}」被拒绝或失败', severity: InfoBarSeverity.error);
    }
  }

  /// 手机端扫码添加设备并立即发起连接。
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
    scope.discovery?.addScanned(peer);
    setState(() => _peer = peer);
    await _connect(peer);
  }

  /// 电脑端展示连接二维码。
  Future<void> _showPairQr() async {
    await showDialog(
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
    final dest = await client.getDestIndex(m.name);
    final destMap = {for (final e in dest) e.relativePath: e};
    final srcMap = await LocalIndexService.scan(m.sourcePath);
    return SyncEngine.computePlan(mapping: m, source: srcMap, dest: destMap);
  }

  Future<SyncPlan> _compareAsReceiver(SyncMapping m, PeerDevice peer) async {
    final client = ReceiverClient(address: peer.address, port: peer.port);
    final src = await client.getIndex(m.name);
    final srcMap = {for (final e in src) e.relativePath: e};
    final destMap = await LocalIndexService.scan(m.destPath);
    return SyncEngine.computePlan(mapping: m, source: srcMap, dest: destMap);
  }

  Future<void> _showCompareResult(SyncMapping m, SyncPlan plan) async {
    final names = plan.newOnly.map((e) => e.relativePath.split('/').last).toList();
    await showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: Text('对比完成 · ${m.name}'),
        content: SizedBox(
          width: 360,
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
    setState(() => _syncing[m.id] = true);

    Future<void> runIt(void Function(int done, int total) onProgress) async {
      if (isSender) {
        final client = SenderClient(address: peer.address, port: peer.port);
        await SyncEngine.push(
          mapping: m,
          client: client,
          files: plan.toSend,
          onProgress: (done, total, current) => onProgress(done, total),
        );
      } else {
        final client = ReceiverClient(address: peer.address, port: peer.port);
        await SyncEngine.run(
          mapping: m,
          client: client,
          files: plan.toSend,
          onProgress: (done, total, current) => onProgress(done, total),
        );
      }
    }

    if (isAndroid) {
      try {
        await WakelockPlus.enable();
      } catch (_) {}
    }
    final success = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SyncDialog(mappingName: m.name, run: runIt),
    );
    if (isAndroid) {
      try {
        await WakelockPlus.disable();
      } catch (_) {}
    }

    if (success == true) {
      await scope.syncLog.add(
        name: m.name,
        fileCount: plan.toSend.length,
        totalBytes: plan.totalBytes,
      );
      if (mounted) {
        setState(() {
          _plans[m.id] = SyncPlan(
            mappingId: m.id,
            mappingName: m.name,
            toSend: const [],
            newOnly: const [],
          );
        });
      }
    }
    if (mounted) setState(() => _syncing[m.id] = false);
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
              child: Text(isLinking ? '连接中…' : (connected ? '已连接' : '连接')),
              onPressed: (isLinking || connected) ? null : () => _connect(d),
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
        return FluentIcons.phone;
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

/// 局域网依赖提示条。
class _LanHint extends StatelessWidget {
  const _LanHint();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Icon(FluentIcons.wifi_warning, size: 20, color: Color(0xFF4A9EFF)),
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

/// 同步进度弹窗：进度条 + 失败原因 / 成功手动关闭。
class _SyncDialog extends StatefulWidget {
  final String mappingName;
  final Future<void> Function(void Function(int done, int total)) run;

  const _SyncDialog({required this.mappingName, required this.run});

  @override
  State<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<_SyncDialog> {
  int _done = 0;
  int _total = 0;
  bool _running = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await widget.run((done, total) {
        if (mounted) setState(() {
          _done = done;
          _total = total;
        });
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
    final progress = _total == 0 ? 0.0 : (_done / _total).clamp(0.0, 1.0);

    return ContentDialog(
      title: Text(finished
          ? (err != null ? '同步失败' : '同步完成')
          : '同步中 · ${widget.mappingName}'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (err != null) ...[
              Text('同步失败，请重试。\n$err',
                  style: const TextStyle(fontSize: 13, color: Color(0xFFE9AA7E))),
            ] else if (finished) ...[
              Text('成功同步 $_done 个文件。',
                  style: const TextStyle(fontSize: 13, color: Color(0xFFc0c0c0))),
            ] else ...[
              Text('正在同步 $_done/$_total',
                  style: const TextStyle(fontSize: 13, color: Color(0xFFc0c0c0))),
              const SizedBox(height: 14),
              ProgressBar(value: progress),
            ],
          ],
        ),
      ),
      actions: [
        if (finished)
          FilledButton(
            child: const Text('关闭'),
            onPressed: () => Navigator.pop(context, err == null),
          ),
      ],
    );
  }
}