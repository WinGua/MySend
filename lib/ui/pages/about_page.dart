import 'package:fluent_ui/fluent_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../widgets/glass.dart';

const _accent = Color(0xFF4A9EFF);
const _muted = Color(0xFF8A8A8A);
const _muted2 = Color(0xFF9A9A9A);

/// 「关于 MySend」介绍页。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: GradientBackground()),
        SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 28),
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(FluentIcons.back, size: 16),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    '关于',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  children: [
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: _accent.withAlpha(38),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(FluentIcons.sync,
                                    size: 24, color: _accent),
                              ),
                              const SizedBox(width: 12),
                              const Text(
                                'MySend',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '局域网单向文件同步工具：把电脑上的文件夹按映射同步到 '
                            'Android 手机 / 平板。一套 Flutter 代码同时构建 '
                            'Windows 发送端与 Android 接收端，界面保持一致。',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.6,
                              color: Color(0xFFB0B0B0),
                            ),
                          ),
                          const SizedBox(height: 14),
                          _line('版本', AppConstants.currentVersion),
                          _line('平台', 'Windows 发送端 / Android 接收端'),
                          _line('传输协议', 'v2 · 会话鉴权 / 断点续传'),
                          _line('发现端口', '${AppConstants.discoveryPort}/udp'),
                          _line('传输端口',
                              '默认 ${AppConstants.transferPort}/http'),
                          _line('日志保留', '7 天'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '同步规则',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '· 仅「电脑 → Android」单向传输\n'
                            '· 只同步目标端不存在的新增文件\n'
                            '· 已存在的文件直接跳过，不比对内容\n'
                            '· 不处理删除，手机端多出的文件不会被清理\n'
                            '· 按相对路径保持目录结构',
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.7,
                                color: _muted2),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '安全说明',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '连接后使用会话 token 鉴权；文件传输先写入目标目录下的 '
                            '.mysend-part 分片，完成后原子替换，中断可续传。\n'
                            '当前使用局域网明文 HTTP 传输，未启用 TLS 加密，'
                            '建议仅在可信的家庭或办公网络内使用。'
                            '应用不会上传任何文件到互联网。',
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.6,
                                color: _muted2),
                          ),
                          const SizedBox(height: 12),
                          Button(
                            onPressed: () async {
                              try {
                                await launchUrl(
                                  Uri.parse(AppConstants.repoUrl),
                                  mode: LaunchMode.externalApplication,
                                );
                              } catch (_) {}
                            },
                            child: const Text('打开 GitHub 仓库',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Built by Winter with DeepSeek',
                      style:
                          TextStyle(fontSize: 11, color: Color(0xFF6F6F6F)),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
