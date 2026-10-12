import 'package:fluent_ui/fluent_ui.dart';

import 'theme.dart';
import 'shell.dart';

class MusicSyncApp extends StatelessWidget {
  const MusicSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return FluentApp(
      title: '音乐同步',
      theme: AppTheme.dark(),
      debugShowCheckedModeBanner: false,
      home: const Shell(),
    );
  }
}
