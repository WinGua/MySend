import 'package:fluent_ui/fluent_ui.dart';

import '../core/constants.dart';
import '../widgets/glass.dart';

/// 「关于 MySend」介绍页。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: GradientBackground()),
        SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 24, 0),
                child: Row(
                  children: [
                    Button(
                      child: const Text('返回'),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 12),
                    const Text('关于 MySend',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _section(
                              '应用简介',
                              'MySend 是一款局域网单向文件同步工具，将电脑（发送端）上的文件'
                              '同步到安卓手机（接收端）。\n\n'
                              '遵循「只同步新增」原则：手机端已存在的同名文件不会重复下载，'
                              '也不处理删除操作，简单又安全。',
                            ),
                            _section(
                              '支持平台',
                              '· Windows（发送端）\n'
                              '· Android（接收端）',
                            ),
                            _section(
                              '功能特性',
                              '· 局域网设备自动发现，支持手动 IP 配对\n'
                              '· 多组目录映射，两端根目录可独立配置\n'
                              '· 只同步新增文件，避免重复覆盖\n'
                              '· Windows 11 磨砂玻璃风格界面，双端一致',
                            ),
                            _section(
                              '技术栈',
                              '· Flutter / Dart\n'
                              '· fluent_ui（Windows 风格 UI）\n'
                              '· 局域网明文 HTTP 传输（后续可扩展加密）',
                            ),
                            _section(
                              '开发声明',
                              'Built by Winter with DeepSeek-V4 Pro',
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '版本 v${AppConstants.currentVersion}',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF9A9A9A)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _section(String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(body,
                style: const TextStyle(
                    fontSize: 13, height: 1.6, color: Color(0xFFC8C8C8))),
          ],
        ),
      ),
    );
  }
}