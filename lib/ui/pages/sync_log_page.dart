import 'package:fluent_ui/fluent_ui.dart';

import '../../app_scope.dart';
import '../../core/utils.dart';
import '../../storage/sync_log_repository.dart';
import '../widgets/glass.dart';

const _accent = Color(0xFF4A9EFF);
const _success = Color(0xFF7BE0A0);
const _muted = Color(0xFF8A8A8A);
const _muted2 = Color(0xFF9A9A9A);

/// 同步日志页：展示每次同步任务的时间、发送/接收文件数与大小，保留最近 7 天。
class SyncLogPage extends StatefulWidget {
  const SyncLogPage({super.key});

  @override
  State<SyncLogPage> createState() => _SyncLogPageState();
}

class _SyncLogPageState extends State<SyncLogPage> {
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    scope.syncLog.addListener(_refresh);
  }

  @override
  void dispose() {
    scope.syncLog.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _clear() async {
    final ok = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: '清空日志',
        content: const Text('确定清空本机保存的全部同步日志吗？'),
        actions: [
          Button(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          FilledButton(
            child: const Text('清空'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok == true) await scope.syncLog.clear();
  }

  @override
  Widget build(BuildContext context) {
    final entries = scope.syncLog.entries;
    return Stack(
      children: [
        const Positioned.fill(child: GradientBackground()),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(FluentIcons.back, size: 16),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text(
                        '同步日志',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '共 ${entries.length} 条',
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                    if (entries.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Button(
                        onPressed: _clear,
                        child: const Text('清空',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(FluentIcons.history,
                                size: 34, color: _muted2),
                            SizedBox(height: 10),
                            Text(
                              '暂无同步记录',
                              style: TextStyle(fontSize: 13, color: _muted),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                        itemCount: entries.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, i) => _logCard(entries[i]),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _logCard(SyncLogEntry e) {
    final key = '${e.time.millisecondsSinceEpoch}|${e.mappingName}';
    final expanded = _expanded.contains(key);
    final hasFiles = e.sentFiles.isNotEmpty || e.receivedFiles.isNotEmpty;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  e.mappingName.isEmpty ? '同步任务' : e.mappingName,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (e.sentCount > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: StatusPill(
                    label: '发出 ${e.sentCount}',
                    color: _accent,
                  ),
                ),
              if (e.receivedCount > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: StatusPill(
                    label: '接收 ${e.receivedCount}',
                    color: _success,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _summary(e),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
          if (hasFiles) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Text(
                  '文件清单',
                  style: TextStyle(fontSize: 11, color: _muted2),
                ),
                const Spacer(),
                Button(
                  onPressed: () => setState(() {
                    if (expanded) {
                      _expanded.remove(key);
                    } else {
                      _expanded.add(key);
                    }
                  }),
                  child: Text(
                    expanded ? '收起' : '查看',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0x14000000),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (e.sentFiles.isNotEmpty)
                      _fileGroup(
                        '已发送 · ${e.sentFiles.length} 个',
                        e.sentFiles,
                      ),
                    if (e.sentFiles.isNotEmpty && e.receivedFiles.isNotEmpty)
                      const SizedBox(height: 8),
                    if (e.receivedFiles.isNotEmpty)
                      _fileGroup(
                        '已接收 · ${e.receivedFiles.length} 个',
                        e.receivedFiles,
                      ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _fileGroup(String title, List<String> files) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 11, color: _muted2),
        ),
        const SizedBox(height: 3),
        for (final f in files)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '· $f',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFFE6E6E6)),
            ),
          ),
      ],
    );
  }

  static String _summary(SyncLogEntry e) {
    final parts = <String>[_fmtTime(e.time)];
    if (e.peerName.isNotEmpty) parts.add('对端 ${e.peerName}');
    if (e.sentCount > 0) parts.add('发送 ${formatBytes(e.sentBytes)}');
    if (e.receivedCount > 0) parts.add('接收 ${formatBytes(e.receivedBytes)}');
    return parts.join(' · ');
  }

  static String _fmtTime(DateTime t) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${pad(t.month)}-${pad(t.day)} '
        '${pad(t.hour)}:${pad(t.minute)}';
  }
}
