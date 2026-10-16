import 'dart:ui' show ImageFilter;

import 'package:fluent_ui/fluent_ui.dart';

import '../app.dart';
import '../app_scope.dart';
import '../core/utils.dart';
import 'pages/home_page.dart';
import 'pages/mappings_page.dart';
import 'pages/settings_page.dart';
import 'widgets/glass.dart';
import 'window_title_bar.dart';

/// 应用导航外壳（Win11 风格侧边栏，手机端自动切换为底部导航）。
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  bool _handlingPair = false;

  static const List<Widget> _pages = <Widget>[
    HomePage(),
    MappingsPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    scope.addListener(_onScopeChanged);
  }

  @override
  void dispose() {
    scope.removeListener(_onScopeChanged);
    super.dispose();
  }

  void _onScopeChanged() {
    if (!mounted) return;
    final r = scope.pairRequest;
    if (r != null && !_handlingPair) {
      _handlingPair = true;
      _showPairDialog(r);
    } else if (r == null) {
      _handlingPair = false;
    }
    setState(() {});
  }

  /// 弹出连接确认弹窗，用户选择后回填结果。
  Future<void> _showPairDialog(PairRequest request) async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) {
      scope.resolvePairRequest(false);
      return;
    }
    final accept = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => ContentDialog(
        title: const Text('连接请求'),
        content: Text(
          '「${request.requester.name}」\n'
          '${request.requester.address}:${request.requester.port}'
          '（${_formLabel(request.requester.form)}）\n'
          '请求与本机建立连接，是否同意？',
        ),
        actions: [
          Button(
            child: const Text('拒绝'),
            onPressed: () => Navigator.pop(dialogCtx, false),
          ),
          FilledButton(
            child: const Text('同意'),
            onPressed: () => Navigator.pop(dialogCtx, true),
          ),
        ],
      ),
    );
    scope.resolvePairRequest(accept ?? false);
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

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    // 手机（窄屏）没有侧边栏空间，改用底部导航；平板 / 桌面用侧边栏。
    final content = width < 640 ? _buildMobile() : _buildDesktop(width);
    return Stack(
      children: [
        const Positioned.fill(child: GradientBackground()),
        content,
      ],
    );
  }

  /// 手机端：内容区 + 底部导航（状态 / 映射 / 设置）。
  Widget _buildMobile() {
    return Column(
      children: [
        Expanded(
          child: SafeArea(
            top: true,
            bottom: false,
            child: IndexedStack(index: _index, children: _pages),
          ),
        ),
        _buildBottomBar(),
      ],
    );
  }

  /// 平板 / 桌面端：自定义侧边栏（避免 NavigationView 的不透明背景遮住渐变底）。
  Widget _buildDesktop(double width) {
    //   < 1008 平板竖屏 → compact（仅图标）；  ≥ 1008 → open（图标 + 文字）
    final open = width >= 1008;
    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSidebar(open),
        Expanded(child: IndexedStack(index: _index, children: _pages)),
      ],
    );

    if (!isWindows) return body;
    return Column(
      children: [
        const WindowTitleBar(),
        Expanded(child: body),
      ],
    );
  }

  /// 半透明侧边栏：透出底层渐变，选中项用左侧高亮色块 + 淡蓝底。
  Widget _buildSidebar(bool open) {
    return Container(
      width: open ? 200 : 68,
      decoration: const BoxDecoration(
        color: Color(0x2E1B222E),
        border: Border(right: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          _sideItem(0, FluentIcons.home, '状态', open),
          _sideItem(1, FluentIcons.folder, '映射', open),
          const Spacer(),
          _sideItem(2, FluentIcons.settings, '设置', open),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _sideItem(int index, IconData icon, String label, bool open) {
    final selected = index == _index;
    final fg = selected ? const Color(0xFF4A9EFF) : const Color(0xFF9A9A9A);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: PressableScale(
        onTap: () => setState(() => _index = index),
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            color: selected ? const Color(0x2E4A9EFF) : const Color(0x00000000),
            borderRadius: BorderRadius.circular(8),
            border: selected
                ? const Border(
                    left: BorderSide(color: Color(0xFF4A9EFF), width: 3),
                  )
                : null,
          ),
          child: Row(
            mainAxisAlignment: open ? MainAxisAlignment.start : MainAxisAlignment.center,
            children: [
              if (open) const SizedBox(width: 12),
              Icon(icon, size: 20, color: fg),
              if (open) ...[
                const SizedBox(width: 12),
                Text(label, style: TextStyle(fontSize: 14, color: fg)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 底部导航栏（仅手机端显示）：悬浮毛玻璃胶囊 + 滑动指示器。
  Widget _buildBottomBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0x33101820),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0x1FFFFFFF)),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final pillWidth = constraints.maxWidth / 3;
                  return Stack(
                    children: [
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        left: _index * pillWidth + 8,
                        top: 8,
                        bottom: 8,
                        width: pillWidth - 16,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0x334A9EFF),
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildBottomItem(0, FluentIcons.home, '状态'),
                          _buildBottomItem(1, FluentIcons.folder, '映射'),
                          _buildBottomItem(2, FluentIcons.settings, '设置'),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomItem(int index, IconData icon, String label) {
    final selected = index == _index;
    final color = selected ? const Color(0xFF4A9EFF) : const Color(0xFF8A8A8A);
    return Expanded(
      child: PressableScale(
        onTap: () => setState(() => _index = index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }
}