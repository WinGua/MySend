import 'package:fluent_ui/fluent_ui.dart';

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
    const pages = <Widget>[
      HomePage(),
      MappingsPage(),
      SettingsPage(),
    ];
    return Column(
      children: [
        Expanded(
          child: SafeArea(
            top: true,
            bottom: false,
            child: pages[_index],
          ),
        ),
        _buildBottomBar(),
      ],
    );
  }

  /// 平板 / 桌面端：Win11 风格侧边栏。
  Widget _buildDesktop(double width) {
    //   640 – 1008  平板竖屏       → compact（紧凑图标列）
    //   ≥ 1008      平板横屏 / 桌面 → open（完整展开侧边栏）
    final PaneDisplayMode displayMode = width < 1008
        ? PaneDisplayMode.compact
        : PaneDisplayMode.open;
    final nav = NavigationView(
      pane: NavigationPane(
        selected: _index,
        onChanged: (i) => setState(() => _index = i),
        displayMode: displayMode,
        items: [
          PaneItem(
            icon: const Icon(FluentIcons.home),
            title: const Text('状态'),
            body: const HomePage(),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.folder),
            title: const Text('映射'),
            body: const MappingsPage(),
          ),
        ],
        footerItems: [
          PaneItem(
            icon: const Icon(FluentIcons.settings),
            title: const Text('设置'),
            body: const SettingsPage(),
          ),
        ],
      ),
    );

    if (!isWindows) return nav;
    return Column(
      children: [
        const WindowTitleBar(),
        Expanded(child: nav),
      ],
    );
  }

  /// 底部导航栏（仅手机端显示）。
  Widget _buildBottomBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF21E1E1E),
        border: Border(top: BorderSide(color: Color(0xFF2E2E2E))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _buildBottomItem(0, FluentIcons.home, '状态'),
            _buildBottomItem(1, FluentIcons.folder, '映射'),
            _buildBottomItem(2, FluentIcons.settings, '设置'),
          ],
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
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}