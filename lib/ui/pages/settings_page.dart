import 'package:fluent_ui/fluent_ui.dart';

import '../../app_scope.dart';
import '../../core/utils.dart';
import '../../platform/permissions.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _name;
  late final TextEditingController _port;
  late bool _syncChanged;

  @override
  void initState() {
    super.initState();
    final cfg = scope.config.config;
    _name = TextEditingController(text: cfg.deviceName);
    _port = TextEditingController(text: '${cfg.transferPort}');
    _syncChanged = cfg.syncChangedFiles;
  }

  @override
  void dispose() {
    _name.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isNotEmpty) scope.config.setDeviceName(name);
    final port = int.tryParse(_port.text.trim());
    if (port != null && port > 0 && port < 65536) {
      scope.config.setTransferPort(port);
    }
    scope.config.setSyncChangedFiles(_syncChanged);
    await scope.startServices(); // 应用新的名称 / 端口 / 配置
    if (mounted) setState(() {});
  }

  Future<void> _requestPermission() async {
    final ok = await ensureFileAccess();
    if (!ok) await openManageStorageSettings();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('设置',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        const Text('设备名称'),
        const SizedBox(height: 4),
        TextBox(controller: _name, placeholder: '例如：客厅电脑'),
        const SizedBox(height: 16),
        const Text('传输端口'),
        const SizedBox(height: 4),
        TextBox(controller: _port, placeholder: '53318'),
        const SizedBox(height: 16),
        Checkbox(
          content: const Text('同时同步「变更」的文件（默认仅同步新增）'),
          checked: _syncChanged,
          onChanged: (v) => setState(() => _syncChanged = v ?? false),
        ),
        const SizedBox(height: 24),
        FilledButton(child: const Text('保存并重启服务'), onPressed: _save),
        if (isAndroid) ...[
          const SizedBox(height: 12),
          Button(
            child: const Text('申请文件访问权限'),
            onPressed: _requestPermission,
          ),
          const SizedBox(height: 8),
          const Text(
            '手机端需要「所有文件访问」权限，才能直接把音乐写入 '
            '/storage/emulated/0/... 的真实目录。',
            style: TextStyle(fontSize: 12, color: Color(0xFF9a9a9a)),
          ),
        ],
      ],
    );
  }
}
