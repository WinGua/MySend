import 'package:fluent_ui/fluent_ui.dart';

import '../../app_scope.dart';
import '../../storage/sync_log_repository.dart';
import '../widgets/glass.dart';

/// 同步日志页面：展示每次同步任务的时间、文件名、文件数与总大小。
class SyncLogPage extends StatefulWidget {
  const SyncLogPage({super.key});

  @override
  State<SyncLogPage> createState() => _SyncLogPageState();
}

class _SyncLogPageState extends State<SyncLogPage> {
  final Set<int> _expanded = {};

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

  @override
  Widget build(BuildContext context) {
    final logs = scope.syncLog.entries;
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('同步日志'),
        leading: IconButton(
          icon: const Icon(FluentIcons.back),
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('共 ${logs.length} 条记录',
                        style: const TextStyle(fontSize: 13, color: Color(0xFF9a9a9a))),
                  ),
                  if (logs.isNotEmpty)
                    Button(
                      child: const Text('清空日志'),
                      onPressed: () => scope.syncLog.clear(),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (logs.isEmpty)
                const Text('暂无同步记录。', style: TextStyle(color: Color(0xFF9a9a9a)))
              else
                for (var i = 0; i < logs.length; i++) _logCard(logs[i], i),
            ],
          ),
        ),
      ),
    );
  }

  Widget _logCard(SyncLogEntry e, int index) {
    final expanded = _expanded.contains(index);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(e.mappingName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(_fmtTime(e.time),
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9a9a9a))),
                const SizedBox(width: 8),
                Button(
                  child: Text(expanded ? '收起' : '文件'),
                  onPressed: () => setState(() {
                    if (expanded) {
                      _expanded.remove(index);
                    } else {
                      _expanded.add(index);
                    }
                  }),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('${e.fileCount} 个文件 · ${_fmtBytes(e.totalBytes)}',
                style: const TextStyle(fontSize: 13, color: Color(0xFFc0c0c0))),
            if (expanded) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0x14000000),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: e.files.isEmpty
                      ? const [
                          Text('（本次无文件名记录）',
                              style: TextStyle(fontSize: 12, color: Color(0xFF9a9a9a))),
                        ]
                      : [
                          for (final f in e.files)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text('· $f',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFFe0e0e0))),
                            ),
                        ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${pad(t.day)} '
        '${pad(t.hour)}:${pad(t.minute)}';
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