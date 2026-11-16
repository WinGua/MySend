import 'package:fluent_ui/fluent_ui.dart';

import 'app_scope.dart';
import 'models/device_info.dart';
import 'services/transfer/pairing_verification.dart';
import 'ui/widgets/pairing_verification_view.dart';
import 'ui/widgets/glass.dart';
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
    scope.onPairRequest = _confirmPair;
    scope.onPairRequestEnded = () => _closePairPrompt?.call();
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

void Function()? _closePairPrompt;
Future<bool> _confirmPair(PeerDevice peer) async {
  final context = appNavigatorKey.currentContext;
  final local = scope.identityFingerprint;
  if (context == null || local == null) return false;
  try {
    return await showGlassDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) {
              _closePairPrompt = () {
                if (ctx.mounted && ModalRoute.of(ctx)?.isCurrent == true) {
                  Navigator.pop(ctx, false);
                }
              };
              return SingleChildScrollView(
                  child: GlassDialog(
                      title: '允许设备配对',
                      content:
                          Column(mainAxisSize: MainAxisSize.min, children: [
                        Text('设备「${peer.name}」请求访问同步目录。\n地址：${peer.address}'),
                        const SizedBox(height: 12),
                        PairingVerificationView(
                            verification:
                                PairingVerification(local, peer.fingerprint)),
                      ]),
                      actions: [
                    Button(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('拒绝')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('允许配对'))
                  ]));
            }) ??
        false;
  } finally {
    _closePairPrompt = null;
  }
}
