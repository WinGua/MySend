import 'package:fluent_ui/fluent_ui.dart';

import 'app_scope.dart';
import 'ui/widgets/remote_sync_dialog_host.dart';
import 'ui/theme.dart';
import 'ui/shell.dart';
import 'ui/startup_gate.dart';

/// 全局导航键，用于在非 widget 上下文（如服务的连接确认回调）中弹窗。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class MySendApp extends StatelessWidget {
  final Future<void> Function(ValueChanged<String>)? initialize;
  final Future<bool> Function()? restartAsAdministrator;
  const MySendApp({super.key, this.initialize, this.restartAsAdministrator});

  @override
  Widget build(BuildContext context) {
    return FluentApp(
      title: 'MySend',
      theme: AppTheme.dark(),
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      home: StartupGate(
          initialize: initialize,
          restartAsAdministrator: restartAsAdministrator,
          child: RemoteSyncDialogHost(
              progress: scope.remoteSync,
              cancel: scope.cancelCurrentSync,
              child: const Shell())),
    );
  }
}