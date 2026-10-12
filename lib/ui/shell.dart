import 'package:fluent_ui/fluent_ui.dart';

import 'pages/home_page.dart';
import 'pages/mappings_page.dart';
import 'pages/settings_page.dart';

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
    return NavigationView(
      pane: NavigationPane(
        selected: _index,
        onChanged: (i) => setState(() => _index = i),
        displayMode: PaneDisplayMode.open,
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
  }
}
