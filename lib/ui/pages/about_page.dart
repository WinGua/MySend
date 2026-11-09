import 'package:fluent_ui/fluent_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../widgets/glass.dart';

const _accent = Color(0xFF4A9EFF);
const _muted = Color(0xFF8A8A8A);
const _body = Color(0xFFBDBDBD);

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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
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
              const SizedBox(height: 12),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _heroCard(),
                      const SizedBox(height: 12),
                      _rulesCard(),
                      const SizedBox(height: 12),
                      _securityCard(),
                      const SizedBox(height: 18),
                      const Center(
                        child: Text(
                          'Built by Winter with DeepSeek',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF6F6F6F)),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _heroCard() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: _accent.withAlpha(38),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(FluentIcons.sync, size: 26, color: _accent),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MySend',
                      style: TextStyle(
                        fontSize: 22,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      '局域网双向文件同步',
                      style: TextStyle(fontSize: 11, color: _muted),
                    ),
                  ],
                ),
              ),
              StatusPill(
                label: 'v${AppConstants.currentVersion}',
                color: _accent,
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            '电脑与 Android 手机 / 平板之间按映射互补新增文件。'
            '任一端点击同步，先发送本机新增，再自动接收对端新增。',
            style: TextStyle(fontSize: 13, height: 1.7, color: _body),
          ),
          const SizedBox(height: 16),
          Container(height: 1, color: const Color(0x1FFFFFFF)),
          const SizedBox(height: 14),
          _line('平台', 'Windows / Android 双端'),
          _line('传输协议', 'v2 · 会话鉴权 / 断点续传'),
          _line('发现端口', '${AppConstants.discoveryPort}/udp'),
          _line('传输端口', '默认 ${AppConstants.transferPort}/http'),
          _line('日志保留', '7 天'),
        ],
      ),
    );
  }

  Widget _rulesCard() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('同步规则', FluentIcons.sync),
          const SizedBox(height: 12),
          _rule('任一端点击同步即可双向互补新增'),
          _rule('只同步对端不存在的新增文件'),
          _rule('两端都有的文件直接跳过，不比对内容'),
          _rule('不覆盖、不删除，对端多出的文件不会被清理'),
          _rule('按相对路径保持目录结构'),
        ],
      ),
    );
  }

  Widget _securityCard() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('安全说明', FluentIcons.info),
          const SizedBox(height: 12),
          const Text(
            '连接后使用会话 token 鉴权；文件传输先写入本机目录下的 '
            '.mysend-part 分片，完成后原子替换，中断可续传。',
            style: TextStyle(fontSize: 12, height: 1.7, color: _body),
          ),
          const SizedBox(height: 8),
          const Text(
            '当前使用局域网明文 HTTP 传输，未启用 TLS 加密，'
            '建议仅在可信的家庭或办公网络内使用。应用不会上传任何文件到互联网。',
            style: TextStyle(fontSize: 12, height: 1.7, color: _body),
          ),
          const SizedBox(height: 14),
          Button(
            onPressed: () async {
              try {
                await launchUrl(
                  Uri.parse(AppConstants.repoUrl),
                  mode: LaunchMode.externalApplication,
                );
              } catch (_) {}
            },
            child: const Text(
              '打开 GitHub 仓库',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: _accent),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _rule(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 4,
            margin: const EdgeInsets.only(top: 7, right: 8),
            decoration: const BoxDecoration(
              color: _accent,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, height: 1.6, color: _body),
            ),
          ),
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
