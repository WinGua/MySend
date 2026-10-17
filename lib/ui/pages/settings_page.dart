import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../platform/permissions.dart';
import '../widgets/glass.dart';
import 'about_page.dart';
import 'sync_log_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _name;
  late final TextEditingController _port;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    final cfg = scope.config.config;
    _name = TextEditingController(text: cfg.deviceName);
    _port = TextEditingController(text: '${cfg.transferPort}');
    scope.syncLog.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    _name.dispose();
    _port.dispose();
    scope.syncLog.removeListener(_onLogChanged);
    super.dispose();
  }

  void _onLogChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isNotEmpty) scope.config.setDeviceName(name);
    final port = int.tryParse(_port.text.trim());
    if (port != null && port > 0 && port < 65536) {
      scope.config.setTransferPort(port);
    }
    await scope.startServices(); // 应用新的名称 / 端口 / 配置
    if (mounted) setState(() {});
  }

  Future<void> _requestPermission() async {
    final ok = await ensureFileAccess();
    if (!ok) await openManageStorageSettings();
  }

  Future<void> _requestBackground() async {
    // 通知权限是前台服务常驻通知的关键；电池优化白名单仅作为更强保活的建议。
    // 部分国产系统（OriginOS 等）对「忽略电池优化」的授权结果返回不可靠，
    // 因此以通知权限结果作为「后台保活是否就绪」的主要依据，避免误报「未成功」。
    final notif = await ensureNotificationPermission();
    final battery = await requestBatteryOptimizationExemption();
    if (!mounted) return;
    final InfoBarSeverity sev;
    final String msg;
    if (notif) {
      sev = InfoBarSeverity.success;
      msg = battery
          ? '后台保活已开启'
          : '后台保活已开启；可再到系统电池/自启动设置中允许本应用后台运行，以获得更稳定保活。';
    } else {
      sev = InfoBarSeverity.warning;
      msg = '通知权限未授权，切后台可能被系统关闭，请到系统设置开启通知。';
    }
    displayInfoBar(
      context,
      builder: (context, close) => InfoBar(
        severity: sev,
        title: Text(msg),
        action: IconButton(
          icon: const Icon(FluentIcons.chrome_close),
          onPressed: close,
        ),
      ),
    );
  }

  void _openAbout() {
    Navigator.of(context).push(
      material.MaterialPageRoute(builder: (_) => const AboutPage()),
    );
  }

  void _openLog() {
    Navigator.of(context).push(
      material.MaterialPageRoute(builder: (_) => const SyncLogPage()),
    );
  }

  Future<void> _openRepo() => _openUrl(AppConstants.repoUrl);

  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // 无法打开外部浏览器时静默忽略。
    }
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final latest = await _fetchLatestVersion();
      final cmp = _compareVersions(latest, AppConstants.currentVersion);
      if (!mounted) return;
      if (cmp > 0) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => GlassDialog(
            title: '发现新版本',
            content:
                Text('最新版本 v$latest，当前版本 v${AppConstants.currentVersion}。'),
            actions: [
              Button(
                child: const Text('取消'),
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
        await showDialog(
          context: context,
          builder: (ctx) => GlassDialog(
            title: '已是最新版本',
            content: Text('当前版本 v${AppConstants.currentVersion} 已是最新。'),
            actions: [
              FilledButton(
                child: const Text('知道了'),
                onPressed: () => Navigator.pop(ctx),
              ),
            ],
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => GlassDialog(
          title: '检查失败',
          content: const Text('无法连接 GitHub，请检查网络后重试。'),
          actions: [
            FilledButton(
              child: const Text('知道了'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
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
      final tag = (j['tag_name'] as String? ?? '').replaceFirst(RegExp(r'^v'), '');
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

  @override
  Widget build(BuildContext context) {
    final logs = scope.syncLog.entries;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
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
            const SizedBox(height: 24),
            FilledButton(child: const Text('保存并重启服务'), onPressed: _save),
            if (isAndroid) ...[
              const SizedBox(height: 12),
              Button(
                child: const Text('申请文件访问权限'),
                onPressed: _requestPermission,
              ),
              const SizedBox(height: 8),
              Button(
                child: const Text('允许后台运行（推荐）'),
                onPressed: _requestBackground,
              ),
              const SizedBox(height: 8),
              const Text(
                '手机端需要「所有文件访问」权限才能写入真实目录；'
                '「允许后台运行」可避免切后台 / 黑屏后掉线。',
                style: TextStyle(fontSize: 12, color: Color(0xFF9a9a9a)),
              ),
            ],
            const SizedBox(height: 32),
            const Text('同步日志',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Button(
                child: const Text('查看同步日志'),
                onPressed: _openLog,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              logs.isEmpty
                  ? '暂无同步记录。'
                  : '最近一条：${logs.first.mappingName} · ${_fmtTime(logs.first.time)}'
                      ' · ${logs.first.fileCount} 个文件 · ${_fmtBytes(logs.first.totalBytes)}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9a9a9a)),
            ),
            const SizedBox(height: 32),
            const Text('更多',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Button(
              child: const Text('关于 MySend'),
              onPressed: _openAbout,
            ),
            const SizedBox(height: 8),
            Button(
              child: const Text('GitHub 仓库'),
              onPressed: _openRepo,
            ),
            const SizedBox(height: 8),
            Button(
              child: Text(_checking ? '检查中…' : '检查更新'),
              onPressed: _checking ? null : _checkUpdate,
            ),
            const SizedBox(height: 12),
            Text('当前版本 v${AppConstants.currentVersion}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9a9a9a))),
          ],
        ),
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${t.month.toString().padLeft(2, '0')}-${pad(t.day)} ${pad(t.hour)}:${pad(t.minute)}';
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