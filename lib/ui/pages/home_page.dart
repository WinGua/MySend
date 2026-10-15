import 'package:fluent_ui/fluent_ui.dart';

import '../../app_scope.dart';
import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../models/device_info.dart';
import '../../models/sync_mapping.dart';
import '../../models/sync_plan.dart';
import '../../services/local_index_service.dart';
import '../../services/sync_engine.dart';
import '../../services/transfer/receiver_client.dart';
import '../widgets/glass.dart';

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
  final List<String> _log = [];

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

  void _addLog(String m) {
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
    setState(() {
      _log.insert(0, '[$ts] $m');
      if (_log.length > 300) _log.removeLast();
    });
  }

  // ---- 对比 & 同步（接收端） ----

  Future<void> _compare(SyncMapping m) async {
    final peer = _peer;
    if (peer == null) {
      _addLog('请先在「可用的发送设备」中选择一台电脑');
      return;
    }
    setState(() => _comparing[m.id] = true);
    try {
      final client = ReceiverClient(address: peer.address, port: peer.port);
      final src = await client.getIndex(m.name);
      final srcMap = {for (final e in src) e.relativePath: e};
      final destMap = await LocalIndexService.scan(m.destPath);
      final plan = SyncEngine.computePlan(
        mapping: m,
        source: srcMap,
        dest: destMap,
      );
      if (mounted) setState(() => _plans[m.id] = plan);
      _addLog('「${m.name}」对比完成：源 ${srcMap.length} / 目标 ${destMap.length}，'
          '新增 ${plan.newOnly.length}');
    } catch (e) {
      _addLog('「${m.name}」对比失败: $e');
    } finally {
      if (mounted) setState(() => _comparing[m.id] = false);
    }
  }

  Future<void> _sync(SyncMapping m) async {
    final peer = _peer;
    final plan = _plans[m.id];
    if (peer == null || plan == null || plan.isEmpty) return;
    setState(() => _syncing[m.id] = true);
    final synced = <String>[];
    try {
      final client = ReceiverClient(address: peer.address, port: peer.port);
      await SyncEngine.run(
        mapping: m,
        client: client,
        files: plan.toSend,
        onProgress: (done, total, current) {
          if (mounted) setState(() {});
          synced.add(current.relativePath.split('/').last);
        },
      );
      if (mounted) {
        final cleared = SyncPlan(
          mappingId: plan.mappingId,
          mappingName: plan.mappingName,
          toSend: const [],
          newOnly: const [],
        );
        setState(() => _plans[m.id] = cleared);
      }
      _addLog(_syncLog(m.destPath, synced));
    } catch (e) {
      _addLog('「${m.name}」同步失败: $e');
    } finally {
      if (mounted) setState(() => _syncing[m.id] = false);
    }
  }

  Future<void> _addManual() async {
    final ip = TextEditingController();
    final port = TextEditingController(text: '${AppConstants.transferPort}');
    await showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('手动添加发送端'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('广播无法覆盖时，可手动填写电脑的 IP 与端口。'),
            const SizedBox(height: 12),
            TextBox(controller: ip, placeholder: 'IP 地址，如 192.168.1.10'),
            const SizedBox(height: 12),
            TextBox(controller: port, placeholder: '端口'),
          ],
        ),
        actions: [
          Button(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(ctx),
          ),
          FilledButton(
            child: const Text('添加'),
            onPressed: () {
              final address = ip.text.trim();
              final p = int.tryParse(port.text.trim()) ?? AppConstants.transferPort;
              if (address.isEmpty) return;
              Navigator.pop(ctx);
              _peer = PeerDevice(
                id: 'manual-$address',
                name: '手动设备 ($address)',
                platform: 'unknown',
                isSender: true,
                address: address,
                port: p,
                lastSeen: DateTime.now(),
                manual: true,
              );
              setState(() {});
              _addLog('已手动添加发送端 $address:$p');
            },
          ),
        ],
      ),
    );
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
            const SizedBox(height: 24),
            _sectionTitle(isSender ? '已发现的接收设备' : '可用的发送设备'),
            for (final d in scope.discovery?.devices ?? const <PeerDevice>[])
              _deviceRow(d),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Button(
                child: const Text('手动添加设备'),
                onPressed: _addManual,
              ),
            ),
            if (!isSender) ...[
              const SizedBox(height: 24),
              _sectionTitle('同步任务'),
              if (cfg.mappings.isEmpty)
                const Text('尚未配置映射，请到「映射」页添加。')
              else
                for (final m in cfg.mappings) _mappingRow(m),
            ],
            const SizedBox(height: 24),
            _sectionTitle('日志'),
            _card(_logPanel()),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      );

  Widget _card(Widget child) => GlassCard(child: child);

  Widget _deviceCard(String deviceName, int transferPort) {
    return Row(
      children: [
        const Icon(FluentIcons.devices2, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(deviceName,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '${isSender ? '发送端（电脑）' : '接收端（安卓）'} · 传输端口 $transferPort'
                '${isSender && (scope.server?.running ?? false) ? ' · 服务运行中' : ''}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9a9a9a)),
              ),
            ],
          ),
        ),
        if (isSender)
          Icon(
            scope.server?.running == true
                ? FluentIcons.radio_bullet
                : FluentIcons.warning,
            size: 20,
          ),
      ],
    );
  }

  Widget _deviceRow(PeerDevice d) {
    final selected = _peer?.id == d.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _card(
        Row(
          children: [
            Icon(d.isSender ? FluentIcons.t_v_monitor : FluentIcons.phone, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${d.platform} · ${d.address}:${d.port}',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF9a9a9a))),
                ],
              ),
            ),
            if (!isSender)
              FilledButton(
                child: Text(selected ? '已选择' : '选择'),
                onPressed: () {
                  setState(() => _peer = d);
                  _addLog('已选择发送端 ${d.name} (${d.address}:${d.port})');
                },
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
      status = '新增 ${plan.newOnly.length} 个，'
          '共 ${_fmtBytes(plan.totalBytes)}';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
              ],
            ),
            const SizedBox(height: 8),
            Text('目标目录：${m.destPath}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9a9a9a))),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  child: Text(comparing ? '对比中…' : '对比'),
                  onPressed: comparing || _peer == null ? null : () => _compare(m),
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
          ],
        ),
      ),
    );
  }

  Widget _logPanel() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SingleChildScrollView(
        reverse: true,
        child: Text(
          _log.isEmpty ? '（暂无日志）' : _log.join('\n'),
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.5),
        ),
      ),
    );
  }

  /// 生成同步完成日志：列出文件名，超过 3 个时只显示前 3 个并加省略号。
  static String _syncLog(String destPath, List<String> names) {
    if (names.isEmpty) return '没有文件需要同步';
    final dir = destPath.isEmpty ? '目标目录' : destPath;
    if (names.length == 1) return '《${names[0]}》已同步到了$dir';
    if (names.length <= 3) {
      return '${names.map((n) => '《$n》').join('、')}已同步到了$dir';
    }
    return '《${names[0]}》《${names[1]}》《${names[2]}》…'
        '共${names.length}个文件已同步到了$dir';
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}