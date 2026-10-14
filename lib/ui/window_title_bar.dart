import 'package:fluent_ui/fluent_ui.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 无边框窗口的自定义标题栏：可拖动 + 最小化/最大化/关闭。
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
          _WinButton(label: '—', onTap: () => windowManager.minimize()),
          _WinButton(
            label: '□',
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _WinButton(
            label: '✕',
            onTap: () => windowManager.close(),
            hoverColor: const Color(0xFFE81123),
          ),
        ],
      ),
    );
  }
}

class _WinButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final Color hoverColor;

  const _WinButton({
    required this.label,
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
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 44,
          height: 40,
          color: _hover ? widget.hoverColor : const Color(0x00000000),
          child: Center(
            child: Text(widget.label, style: const TextStyle(fontSize: 12)),
          ),
        ),
      ),
    );
  }
}