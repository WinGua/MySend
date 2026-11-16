import 'dart:io';
import 'package:fluent_ui/fluent_ui.dart';
import '../services/windows_privileges.dart';
import 'package:flutter/services.dart';
import '../core/utils.dart';
import 'window_title_bar.dart';

/// 首帧先显示启动状态；配置和网络初始化不会阻止窗口绘制。
class StartupGate extends StatefulWidget {
  final Future<void> Function(ValueChanged<String>)? initialize;
  final Widget child;
  final Future<bool> Function()? restartAsAdministrator;
  const StartupGate(
      {super.key,
      this.initialize,
      this.restartAsAdministrator,
      required this.child});
  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool _ready = false;
  String _stage = '正在启动 MySend';
  String? _error;
  bool _permissionFailure = false;
  bool? _isElevated;
  bool _restarting = false;
  bool _automaticElevationAttempted = false;
  String? _restartMessage;
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
    if (!mounted || _restarting) return;
    setState(() {
      _error = null;
      _permissionFailure = false;
      _restartMessage = null;
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
          _permissionFailure = error is PathAccessException ||
              (error is FileSystemException &&
                  [5, 13].contains(error.osError?.errorCode));
        });
      }
      if (_permissionFailure && widget.restartAsAdministrator != null) {
        _checkPrivileges();
      }
    }
  }

  Future<void> _checkPrivileges() async {
    try {
      final elevated = await WindowsPrivileges.isElevated();
      if (!mounted || !_permissionFailure || _ready) return;
      setState(() {
        _isElevated = elevated;
      });
      if (!elevated && !_automaticElevationAttempted) {
        // Only one automatic UAC request per startup gate. Cancellation or a
        // failed restart must not turn Retry into a repeated system prompt.
        _automaticElevationAttempted = true;
        await _restartElevated();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _restartMessage = '无法读取管理员状态：${error.runtimeType}';
        });
      }
    }
  }

  Future<void> _restartElevated() async {
    if (_restarting) return;
    setState(() {
      _restarting = true;
      _restartMessage = null;
    });
    try {
      final started = await widget.restartAsAdministrator!();
      if (mounted) {
        setState(() {
          _restartMessage = started ? '管理员实例已启动' : '已取消管理员授权，当前窗口保持普通权限';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _restartMessage = '管理员重启失败：$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _restarting = false;
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
                  ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: SingleChildScrollView(
                          child: SelectableText(_error!,
                              style: const TextStyle(fontSize: 12)))),
                  const SizedBox(height: 16),
                  Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                            onPressed: _restarting ? null : _start,
                            child: const Text('重试')),
                        if (_permissionFailure &&
                            widget.restartAsAdministrator != null &&
                            _isElevated == false)
                          Button(
                              onPressed: _restarting ? null : _restartElevated,
                              child: Text(_restarting
                                  ? '等待 Windows 授权…'
                                  : '以管理员身份重新启动')),
                        Button(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(
                                  text: 'MySend 启动失败\n$_stage\n$_error'));
                            },
                            child: const Text('复制诊断信息')),
                      ]),
                  if (_permissionFailure && _isElevated == true)
                    const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text('当前已是管理员权限；仍需检查此目录的访问权限。')),
                  if (_restartMessage != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_restartMessage!)),
                ],
              ])),
        ))));
    return isWindows
        ? Column(children: [const WindowTitleBar(), Expanded(child: panel)])
        : panel;
  }
}
