import 'package:fluent_ui/fluent_ui.dart';

import 'ui/theme.dart';
import 'ui/shell.dart';

/// 全局导航键，用于在非 widget 上下文（如服务的连接确认回调）中弹窗。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class MySendApp extends StatelessWidget {
  const MySendApp({super.key});

  @override
  Widget build(BuildContext context) {
    return FluentApp(
      title: 'MySend',
      theme: AppTheme.dark(),
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      home: const Shell(),
    );
  }
}