import 'package:fluent_ui/fluent_ui.dart';

import '../../app_scope.dart';
import '../../core/utils.dart';
import '../../models/sync_mapping.dart';
import '../../platform/folder_picker.dart';
import '../../platform/permissions.dart';
import '../widgets/glass.dart';

const _accent = Color(0xFF4A9EFF);
const _muted = Color(0xFF8A8A8A);
const _muted2 = Color(0xFF9A9A9A);

class MappingsPage extends StatefulWidget {
  const MappingsPage({super.key});

  @override
  State<MappingsPage> createState() => _MappingsPageState();
}

class _MappingsPageState extends State<MappingsPage> {
  @override
  void initState() {
    super.initState();
    scope.config.addListener(_refresh);
  }

  @override
  void dispose() {
    scope.config.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _openEditor({SyncMapping? existing}) async {
    final result = await showGlassDialog<SyncMapping>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _MappingEditor(
        existing: existing,
        onSaved: (m) => Navigator.pop(ctx, m),
        onCancel: () => Navigator.pop(ctx),
      ),
    );
    if (result == null) return;
    if (existing == null) {
      scope.config.addMapping(result);
    } else {
      scope.config.updateMapping(result);
    }
    if (mounted) setState(() {});
  }

  Future<void> _delete(SyncMapping m) async {
    final ok = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: '删除映射',
        content: Text('确定删除「${m.name}」吗？手机上的文件不会被删除。'),
        actions: [
          Button(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          FilledButton(
            child: const Text('删除'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok == true) scope.config.removeMapping(m.id);
  }

  @override
  Widget build(BuildContext context) {
    final mappings = scope.config.config.mappings;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
          children: [
            PageHeader(
              title: '映射',
              subtitle: isSender
                  ? '为每组同步任务选择电脑上的源目录；手机端配置同名映射的目标目录。'
                  : '为每组同步任务选择手机上的目标目录；电脑端配置同名映射的源目录。',
              trailing: FilledButton(
                onPressed: () => _openEditor(),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.add, size: 14),
                    SizedBox(width: 6),
                    Text('新增映射', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (mappings.isEmpty)
              const GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(FluentIcons.folder, size: 20, color: _accent),
                        SizedBox(width: 10),
                        Text('暂无映射',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      '点击右上角「新增映射」创建第一组目录映射。'
                      '两端映射名称保持一致即可配对。',
                      style: TextStyle(
                          fontSize: 12, height: 1.5, color: _muted2),
                    ),
                  ],
                ),
              )
            else
              for (final m in mappings) ...[
                _mappingCard(m),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }

  Widget _mappingCard(SyncMapping m) {
    final path = isSender ? m.sourcePath : m.destPath;
    final roleLabel = isSender ? '源目录' : '目标目录';
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.folder, size: 20, color: _accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  m.name,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(FluentIcons.edit, size: 16),
                onPressed: () => _openEditor(existing: m),
              ),
              IconButton(
                icon: const Icon(FluentIcons.delete, size: 16),
                onPressed: () => _delete(m),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$roleLabel：${path.isEmpty ? '（未填写）' : path}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, height: 1.5, color: _muted),
          ),
          if (isSender && m.destPath.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '手机目标目录：${m.destPath}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: _muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// 新增 / 编辑映射弹窗。
class _MappingEditor extends StatefulWidget {
  final SyncMapping? existing;
  final void Function(SyncMapping) onSaved;
  final VoidCallback onCancel;

  const _MappingEditor({
    required this.existing,
    required this.onSaved,
    required this.onCancel,
  });

  @override
  State<_MappingEditor> createState() => _MappingEditorState();
}

class _MappingEditorState extends State<_MappingEditor> {
  late final TextEditingController _name;
  late final TextEditingController _source;
  late final TextEditingController _dest;
  String? _error;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _source = TextEditingController(text: e?.sourcePath ?? '');
    _dest = TextEditingController(text: e?.destPath ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _source.dispose();
    _dest.dispose();
    super.dispose();
  }

  Future<void> _pickSource() async {
    setState(() => _picking = true);
    final picked = await FolderPicker.pick();
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (picked != null && picked.isNotEmpty) {
        _source.text = picked;
        _error = null;
      }
    });
  }

  Future<void> _pickDest() async {
    setState(() => _picking = true);
    if (isAndroid) {
      final granted = await ensureFileAccess();
      if (!granted) {
        if (mounted) {
          setState(() {
            _picking = false;
            _error = '未获得文件访问权限，请在系统设置中开启「所有文件访问」后重试。';
          });
        }
        return;
      }
    }
    final picked = await FolderPicker.pick();
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (picked != null && picked.isNotEmpty) {
        _dest.text = picked;
        _error = null;
      }
    });
  }

  void _save() {
    final name = _name.text.trim();
    final source = _source.text.trim();
    final dest = _dest.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写映射名称。');
      return;
    }
    final duplicated = scope.config.config.mappings.any(
      (m) => m.name == name && m.id != widget.existing?.id,
    );
    if (duplicated) {
      setState(() => _error = '映射名称已存在，请换一个名称。');
      return;
    }
    if (isSender && source.isEmpty) {
      setState(() => _error = '请选择电脑上的源目录。');
      return;
    }
    if (!isSender && dest.isEmpty) {
      setState(() => _error = '请选择手机上的目标目录。');
      return;
    }
    widget.onSaved(
      SyncMapping(
        id: widget.existing?.id ?? newUuid(),
        name: name,
        sourcePath: source,
        destPath: dest,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassDialog(
      title: widget.existing == null ? '新增映射' : '编辑映射',
      maxWidth: 460,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('映射名称（两端保持一致）',
              style: TextStyle(fontSize: 12, color: _muted)),
          const SizedBox(height: 6),
          TextBox(
            controller: _name,
            placeholder: '例如：音乐',
          ),
          const SizedBox(height: 14),
          if (isSender) ...[
            const Text('源目录（电脑）',
                style: TextStyle(fontSize: 12, color: _muted)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextBox(
                    controller: _source,
                    placeholder: '选择电脑上的文件夹',
                    readOnly: true,
                  ),
                ),
                const SizedBox(width: 8),
                Button(
                  onPressed: _picking ? null : _pickSource,
                  child: _picking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: ProgressRing(strokeWidth: 2),
                        )
                      : const Text('选择', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('目标目录（手机，可留空）',
                style: TextStyle(fontSize: 12, color: _muted)),
            const SizedBox(height: 6),
            TextBox(
              controller: _dest,
              placeholder: '在手机端配置即可',
            ),
          ] else ...[
            const Text('目标目录（手机）',
                style: TextStyle(fontSize: 12, color: _muted)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextBox(
                    controller: _dest,
                    placeholder: '点击右侧按钮选择',
                    readOnly: true,
                  ),
                ),
                const SizedBox(width: 8),
                Button(
                  onPressed: _picking ? null : _pickDest,
                  child: _picking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: ProgressRing(strokeWidth: 2),
                        )
                      : const Text('选择', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '首次选择目录会请求「所有文件访问」权限，授权后即可写入真实路径。',
              style: TextStyle(fontSize: 11, height: 1.5, color: _muted),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: Color(0xFFFF9B9B)),
            ),
          ],
        ],
      ),
      actions: [
        Button(child: const Text('取消'), onPressed: widget.onCancel),
        FilledButton(child: const Text('保存'), onPressed: _save),
      ],
    );
  }
}
