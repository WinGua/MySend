import 'package:fluent_ui/fluent_ui.dart';

import '../core/utils.dart';
import 'pages/home_page.dart';
import 'pages/mappings_page.dart';
import 'pages/settings_page.dart';
import 'window_title_bar.dart';

/// 应用导航外壳（Win11 风格侧边栏）。
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
    // 响应式导航，兼顾手机 / 平板 / 桌面：
    //   < 640       手机          → minimal（仅汉堡按钮，点开展开，不挤占内容区）
    //   640 – 1008  平板竖屏       → compact（紧凑图标列）
    //   ≥ 1008      平板横屏 / 桌面 → open（完整展开侧边栏）
    final PaneDisplayMode displayMode = width < 640
        ? PaneDisplayMode.minimal
        : width < 1008
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
}
