import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import '../core/utils.dart';
import 'window_title_bar.dart';

/// 首帧先显示启动状态；配置和网络初始化不会阻止窗口绘制。
class StartupGate extends StatefulWidget {
  final Future<void> Function(ValueChanged<String>)? initialize;
  final Widget child;
  const StartupGate({super.key, this.initialize, required this.child});
  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool _ready = false;
  String _stage = '正在启动 MySend';
  String? _error;
  @override
  void initState() {
    super.initState();
    _ready = widget.initialize == null;
    if (!_ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _start();
      });
    }
  }

  Future<void> _start() async {
    if (!mounted) return;
    setState(() {
      _error = null;
      _stage = '正在启动 MySend';
    });
    try {
      await widget.initialize!((stage) {
        if (mounted) {
          setState(() {
            _stage = stage;
          });
        }
      });
      if (mounted) {
        setState(() {
          _ready = true;
        });
      }
    } catch (error, stack) {
      // 服务保持失败状态，显示诊断信息供重试，绝不降级为不安全传输。
      final message =
          error is FormatException ? error.message : error.toString();
      if (mounted) {
        setState(() {
          _error = '$message\n\n$stack';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    final panel = ColoredBox(
        color: const Color(0xFF1B222E),
        child: Center(
            child: SingleChildScrollView(
                child: Padding(
          padding: const EdgeInsets.all(24),
          child: SizedBox(
              width: 560,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('MySend',
                    style:
                        TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
                const SizedBox(height: 24),
                if (_error == null) const ProgressRing(),
                const SizedBox(height: 16),
                Text(_error == null ? _stage : '启动失败 · $_stage'),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  SelectableText(_error!, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 16),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    FilledButton(onPressed: _start, child: const Text('重试')),
                    const SizedBox(width: 12),
                    Button(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(
                              text: 'MySend 启动失败\n$_stage\n$_error'));
                        },
                        child: const Text('复制诊断信息')),
                  ]),
                ],
              ])),
        ))));
    return isWindows
        ? Column(children: [const WindowTitleBar(), Expanded(child: panel)])
        : panel;
  }
}
