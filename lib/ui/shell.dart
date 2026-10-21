import 'dart:ui' show ImageFilter;

import 'package:fluent_ui/fluent_ui.dart';

import '../app_scope.dart';
import '../core/utils.dart';
import 'pages/home_page.dart';
import 'pages/mappings_page.dart';
import 'pages/settings_page.dart';
import 'widgets/glass.dart';
import 'window_title_bar.dart';

const _accent = Color(0xFF4A9EFF);
const _muted = Color(0xFF8A8A8A);
const _muted2 = Color(0xFF9A9A9A);

/// 应用导航外壳：手机使用悬浮底部导航，平板 / 桌面使用侧边栏。
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

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
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final content = width < 640 ? _buildMobile() : _buildDesktop(width);
    return Stack(
      children: [
        const Positioned.fill(child: GradientBackground()),
        content,
      ],
    );
  }

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

  Widget _buildDesktop(double width) {
    final open = width >= 1008;
    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSidebar(open),
        Expanded(
          child: IndexedStack(index: _index, children: _pages),
        ),
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

  Widget _buildSidebar(bool open) {
    return Container(
      width: open ? 200 : 68,
      decoration: const BoxDecoration(
        color: Color(0x2E1B222E),
        border: Border(right: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 18),
            _brand(open),
            const SizedBox(height: 18),
            _sideItem(0, FluentIcons.home, '状态', open),
            _sideItem(1, FluentIcons.folder, '映射', open),
            const Spacer(),
            _sideItem(2, FluentIcons.settings, '设置', open),
            const SizedBox(height: 14),
          ],
        ),
      ),
    );
  }

  Widget _brand(bool open) {
    if (!open) {
      return const Center(
        child: SizedBox(
          width: 36,
          height: 36,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0x2E4A9EFF),
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
            child: Icon(FluentIcons.sync, size: 20, color: _accent),
          ),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0x2E4A9EFF),
                borderRadius: BorderRadius.all(Radius.circular(9)),
              ),
              child: Icon(FluentIcons.sync, size: 18, color: _accent),
            ),
          ),
          SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MySend',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 1),
              Text(
                '局域网同步',
                style: TextStyle(fontSize: 10, color: _muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sideItem(int index, IconData icon, String label, bool open) {
    final selected = index == _index;
    final fg = selected ? _accent : _muted2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: PressableScale(
        onTap: () => setState(() => _index = index),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: selected ? const Color(0x2E4A9EFF) : const Color(0x00000000),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment:
                open ? MainAxisAlignment.start : MainAxisAlignment.center,
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
    final color = selected ? _accent : _muted;
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
