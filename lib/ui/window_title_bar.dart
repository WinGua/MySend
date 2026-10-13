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
                    '音乐同步',
                    style: TextStyle(fontSize: 13, color: Color(0xFF9a9a9a)),
                  ),
                ),
              ),
            ),
          ),
          _winButton('—', () => windowManager.minimize()),
          _winButton('□', () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          }),
          _winButton('✕', () => windowManager.close()),
        ],
      ),
    );
  }

  Widget _winButton(String label, VoidCallback onTap) {
    return SizedBox(
      width: 44,
      height: 40,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}
