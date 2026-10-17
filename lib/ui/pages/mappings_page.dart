import 'package:fluent_ui/fluent_ui.dart';

import '../../app_scope.dart';
import '../../core/utils.dart';
import '../../models/sync_mapping.dart';
import '../../platform/folder_picker.dart';
import '../../platform/permissions.dart';
import '../widgets/glass.dart';

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

  Future<void> _openForm({SyncMapping? existing}) async {
    final result = await showDialog<SyncMapping>(
      context: context,
      builder: (ctx) => _MappingFormDialog(existing: existing),
    );
    if (result == null) return;
    if (existing == null) {
      scope.config.addMapping(result);
    } else {
      scope.config.updateMapping(result);
    }
  }

  Future<void> _delete(SyncMapping m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: '删除映射',
        content: Text('确定删除映射「${m.name}」吗？不会删除任何实际文件。'),
        actions: [
          Button(child: const Text('取消'), onPressed: () => Navigator.pop(ctx, false)),
          FilledButton(child: const Text('删除'), onPressed: () => Navigator.pop(ctx, true)),
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
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('路径映射',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              '每一组映射用「名称」把电脑与手机上的目录配对。电脑端填源目录，'
              '手机端填目标目录，两端名称保持一致即可。',
              style: TextStyle(fontSize: 12, color: Color(0xFF9a9a9a)),
            ),
            const SizedBox(height: 16),
            if (mappings.isEmpty)
              const Text('还没有映射，点击下方「添加映射」开始。')
            else
              for (final m in mappings) _mappingTile(m),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                child: const Text('添加映射'),
                onPressed: () => _openForm(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mappingTile(SyncMapping m) {
    final usedPath = isSender ? m.sourcePath : m.destPath;
    final roleLabel = isSender ? '源目录' : '目标目录';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(FluentIcons.folder, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${m.name}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('$roleLabel：${usedPath.isEmpty ? '（未填写）' : usedPath}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF9a9a9a))),
                ],
              ),
            ),
            Button(
              child: const Text('编辑'),
              onPressed: () => _openForm(existing: m),
            ),
            const SizedBox(width: 8),
            Button(
              child: const Text('删除'),
              onPressed: () => _delete(m),
            ),
          ],
        ),
      ),
    );
  }
}

/// 新增 / 编辑映射的表单对话框。
class _MappingFormDialog extends StatefulWidget {
  final SyncMapping? existing;
  const _MappingFormDialog({this.existing});

  @override
  State<_MappingFormDialog> createState() => _MappingFormDialogState();
}

class _MappingFormDialogState extends State<_MappingFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _source;
  late final TextEditingController _dest;

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
    final p = await FolderPicker.pick();
    if (p != null && p.isNotEmpty) _source.text = p;
  }

  Future<void> _pickDest() async {
    if (isAndroid) {
      // 安卓端先确保「所有文件访问」权限（用于写入真实路径），再打开目录选择器。
      final ok = await ensureFileAccess();
      if (!ok) {
        await openManageStorageSettings();
        return;
      }
    }
    final p = await FolderPicker.pick();
    if (p != null && p.isNotEmpty) _dest.text = p;
  }

  @override
  Widget build(BuildContext context) {
    return GlassDialog(
      title: widget.existing == null ? '添加映射' : '编辑映射',
      maxWidth: 460,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('名称（两端保持一致）'),
          TextBox(controller: _name, placeholder: '例如：中文、摇滚、爵士'),
          const SizedBox(height: 16),
          Text(isSender ? '源目录（电脑）' : '目标目录（手机）'),
          Row(
            children: [
              Expanded(child: TextBox(controller: isSender ? _source : _dest)),
              const SizedBox(width: 8),
              Button(
                child: const Text('浏览'),
                onPressed: isSender ? _pickSource : _pickDest,
              ),
            ],
          ),
          if (!isSender)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '手机端请填写真实绝对路径，例如 /storage/emulated/0/Music/中文。'
                '首次点击「浏览」会请求文件访问权限。',
                style: TextStyle(fontSize: 12, color: Color(0xFF9a9a9a)),
              ),
            ),
          if (isSender)
            const SizedBox(height: 16),
          if (isSender) ...[
            const Text('目标目录（手机端，可暂不填）'),
            TextBox(controller: _dest, placeholder: '在手机端配置即可'),
          ],
        ],
      ),
      actions: [
        Button(child: const Text('取消'), onPressed: () => Navigator.pop(context)),
        FilledButton(
          child: const Text('保存'),
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(
              context,
              SyncMapping(
                id: widget.existing?.id ?? newUuid(),
                name: name,
                sourcePath: _source.text.trim(),
                destPath: _dest.text.trim(),
              ),
            );
          },
        ),
      ],
    );
  }
}