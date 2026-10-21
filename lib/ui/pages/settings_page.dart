import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../core/constants.dart';
import '../../core/utils.dart';
import '../widgets/glass.dart';
import 'about_page.dart';
import 'sync_log_page.dart';

const _accent = Color(0xFF4A9EFF);
const _muted = Color(0xFF8A8A8A);

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    scope.syncLog.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    scope.syncLog.removeListener(_onLogChanged);
    super.dispose();
  }

  void _onLogChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _editDeviceName() async {
    final ctrl = TextEditingController(text: scope.config.config.deviceName);
    final name = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: '设备名称',
        maxWidth: 380,
        content: TextBox(
          controller: ctrl,
          placeholder: '例如：我的手机',
        ),
        actions: [
          Button(child: const Text('取消'), onPressed: () => Navigator.pop(ctx)),
          FilledButton(
            child: const Text('保存'),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          ),
        ],
      ),
    );
    disposeControllerLater(ctrl);
    if (name == null || name.isEmpty) return;
    scope.config.setDeviceName(name);
    await _restartServices();
    if (mounted) await _notice('已保存', '设备名称已更新为「$name」。');
  }

  Future<void> _editPort() async {
    final ctrl = TextEditingController(
      text: '${scope.config.config.transferPort}',
    );
    final raw = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: '服务端口',
        maxWidth: 380,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextBox(
              controller: ctrl,
              placeholder: '53318',
            ),
            const SizedBox(height: 8),
            const Text(
              '默认 53318，范围 1024–65535。修改后会重启局域网服务。',
              style: TextStyle(fontSize: 12, color: _muted),
            ),
          ],
        ),
        actions: [
          Button(child: const Text('取消'), onPressed: () => Navigator.pop(ctx)),
          FilledButton(
            child: const Text('保存'),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          ),
        ],
      ),
    );
    disposeControllerLater(ctrl);
    if (raw == null) return;
    final port = int.tryParse(raw);
    if (port == null || port < 1024 || port > 65535) {
      if (mounted) await _notice('端口无效', '请输入 1024–65535 之间的端口号。');
      return;
    }
    scope.config.setTransferPort(port);
    await _restartServices();
    if (mounted) await _notice('已保存', '服务端口已切换为 $port。');
  }

  Future<void> _restartServices() async {
    await scope.startServices();
    if (mounted) setState(() {});
  }

  void _openAbout() {
    Navigator.of(context).push(
      material.PageRouteBuilder(
        pageBuilder: (_, __, ___) => const AboutPage(),
        transitionsBuilder: (_, anim, __, child) =>
            material.FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  void _openLog() {
    Navigator.of(context).push(
      material.PageRouteBuilder(
        pageBuilder: (_, __, ___) => const SyncLogPage(),
        transitionsBuilder: (_, anim, __, child) =>
            material.FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  Future<void> _openRepo() => _openUrl(AppConstants.repoUrl);

  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final latest = await _fetchLatestVersion();
      final cmp = _compareVersions(latest, AppConstants.currentVersion);
      if (!mounted) return;
      if (cmp > 0) {
        final go = await showGlassDialog<bool>(
          context: context,
          builder: (ctx) => GlassDialog(
            title: '发现新版本',
            content: Text(
              '最新版本 v$latest，当前版本 v${AppConstants.currentVersion}。',
            ),
            actions: [
              Button(
                child: const Text('稍后'),
                onPressed: () => Navigator.pop(ctx, false),
              ),
              FilledButton(
                child: const Text('前往下载'),
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        );
        if (go == true) await _openUrl(AppConstants.releasesUrl);
      } else {
        await _notice('已是最新版本',
            '当前版本 v${AppConstants.currentVersion} 已是最新。');
      }
    } catch (_) {
      if (mounted) await _notice('检查更新失败', '无法连接 GitHub，请检查网络后重试。');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<String> _fetchLatestVersion() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(AppConstants.releasesApiUrl));
      req.headers.set(HttpHeaders.userAgentHeader, 'MySend');
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final text = await res.transform(utf8.decoder).join();
      final j = jsonDecode(text) as Map<String, dynamic>;
      final tag = (j['tag_name'] as String? ?? '')
          .replaceFirst(RegExp(r'^[vV]'), '');
      if (tag.isEmpty) throw const FormatException('tag_name 为空');
      return tag;
    } finally {
      client.close();
    }
  }

  int _compareVersions(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }

  Future<void> _notice(String title, String text) {
    return showGlassDialog<void>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: title,
        maxWidth: 340,
        content: Text(text, style: const TextStyle(fontSize: 13, height: 1.4)),
        actions: [
          FilledButton(
            child: const Text('知道了'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cfg = scope.config.config;
    final logs = scope.syncLog.entries;
    final logSubtitle = logs.isEmpty
        ? '暂无同步记录'
        : '最近：${logs.first.mappingName} · '
            '${_fmtTime(logs.first.time)} · '
            '${logs.first.fileCount} 个文件';

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
          children: [
            const AppPageHeader(
              title: '设置',
              subtitle: '设备信息、同步日志与应用更新',
            ),
            const SizedBox(height: 18),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  _tile(
                    icon: FluentIcons.rename,
                    title: '设备名称',
                    subtitle: cfg.deviceName,
                    onTap: _editDeviceName,
                  ),
                  _divider(),
                  _tile(
                    icon: FluentIcons.plug_connected,
                    title: '服务端口',
                    subtitle: '${cfg.transferPort}',
                    onTap: _editPort,
                  ),
                  _divider(),
                  _tile(
                    icon: FluentIcons.history,
                    title: '同步日志',
                    subtitle: logSubtitle,
                    onTap: _openLog,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  _tile(
                    icon: FluentIcons.info,
                    title: '关于',
                    subtitle: 'MySend ${AppConstants.currentVersion}',
                    onTap: _openAbout,
                  ),
                  _divider(),
                  _tile(
                    icon: FluentIcons.globe,
                    title: 'GitHub 仓库',
                    subtitle: 'WinGua/MySend',
                    onTap: _openRepo,
                  ),
                  _divider(),
                  _tile(
                    icon: FluentIcons.sync,
                    title: '检查更新',
                    subtitle: _checking
                        ? '正在检查…'
                        : '与 GitHub Releases 比对版本',
                    trailing: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: ProgressRing(strokeWidth: 2),
                          )
                        : null,
                    onTap: _checking ? null : _checkUpdate,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Center(
              child: Text(
                'MySend v${AppConstants.currentVersion} · Built by Winter with DeepSeek',
                style: TextStyle(fontSize: 11, color: Color(0xFF6F6F6F)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(
        height: 1,
        margin: const EdgeInsets.symmetric(horizontal: 14),
        color: const Color(0x14FFFFFF),
      );

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: _accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 11, color: _muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (trailing != null)
              trailing
            else
              const Icon(FluentIcons.chevron_right,
                  size: 12, color: Color(0xFF6F6F6F)),
          ],
        ),
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${pad(t.month)}-${pad(t.day)} ${pad(t.hour)}:${pad(t.minute)}';
  }
}
