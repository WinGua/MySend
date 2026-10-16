import 'package:fluent_ui/fluent_ui.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 无边框窗口的自定义标题栏：可拖动 + 最小化/最大化/关闭。
/// 三个窗口按钮与全应用按钮保持同一套 Fluent 风格（图标 + 悬停态），仅关闭键用红。
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
              onPanStart: (_) => windowManager.startDragging(),
              child: const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(left: 16),
                  child: Text(
                    'MySend',
                    style: TextStyle(fontSize: 13, color: Color(0xFF9a9a9a)),
                  ),
                ),
              ),
            ),
          ),
          _WinButton(
            icon: FluentIcons.chrome_minimize,
            tooltip: '最小化',
            onTap: () => windowManager.minimize(),
          ),
          _WinButton(
            icon: FluentIcons.chrome_restore,
            tooltip: '最大化',
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _WinButton(
            icon: FluentIcons.chrome_close,
            tooltip: '关闭',
            onTap: () => windowManager.close(),
            hoverColor: const Color(0xFFE81123),
          ),
        ],
      ),
    );
  }
}

class _WinButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color hoverColor;

  const _WinButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.hoverColor = const Color(0x22FFFFFF),
  });

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 46,
            height: 40,
            color: _hover ? widget.hoverColor : const Color(0x00000000),
            child: Icon(widget.icon, size: 12, color: const Color(0xFFD0D0D0)),
          ),
        ),
      ),
    );
  }
}