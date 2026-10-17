import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart' as material;
import 'package:flutter/widgets.dart';

/// 跨平台统一的磨砂玻璃视觉组件集合。
///
/// 这里只依赖 Flutter 内置能力（`BackdropFilter` + 渐变 + 缩放动画），
/// 不引入任何额外依赖，Windows / Android 通用，避免构建失败风险。

/// 底层渐变 + 柔光背景，为毛玻璃卡片提供可被模糊的「色彩底」。
class GradientBackground extends StatelessWidget {
  const GradientBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: const [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF1B2534), Color(0xFF0D1016)],
            ),
          ),
        ),
        Positioned(
          top: -140,
          left: -100,
          child: _Glow(size: 380, color: Color(0x334A9EFF)),
        ),
        Positioned(
          bottom: -160,
          right: -120,
          child: _Glow(size: 440, color: Color(0x2E7C5CFF)),
        ),
      ],
    );
  }
}

/// 单个柔光光斑（径向渐变到全透明）。
class _Glow extends StatelessWidget {
  final double size;
  final Color color;

  const _Glow({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, color.withAlpha(0)],
        ),
      ),
    );
  }
}

/// 毛玻璃卡片：背景模糊 + 半透明填充 + 细高光边框 + 圆角。
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;

  const GlassCard({super.key, required this.child, this.padding});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: padding ?? const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0x1FFFFFFF)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 悬停/按下时的轻微缩放动画（移动端按下反馈 + 桌面端悬停反馈）。
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const PressableScale({super.key, required this.child, this.onTap});

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _hovered = false;
  bool _pressed = false;

  double get _scale {
    if (_pressed) return 0.96;
    if (_hovered) return 1.02;
    return 1.0;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: widget.onTap == null
            ? null
            : (_) => setState(() => _pressed = true),
        onTapUp: widget.onTap == null
            ? null
            : (_) => setState(() => _pressed = false),
        onTapCancel: widget.onTap == null
            ? null
            : () => setState(() => _pressed = false),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 1.0, end: _scale),
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          builder: (context, value, child) =>
              Transform.scale(scale: value, child: child),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 磨砂玻璃弹窗容器：统一所有对话框的 Windows11 毛玻璃视觉。
///
/// 用法：`showGlassDialog(context: context, builder: (_) => GlassDialog(...))`，
/// 取代默认的 `ContentDialog`，使对比结果、同步进度、热点组网、更新提示等
/// 所有弹窗都使用同一套玻璃风格。
class GlassDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;
  final double maxWidth;

  const GlassDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.maxWidth = 340,
  });

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    // 宽度由内容驱动（Container shrink-wrap），仅用上限约束防止溢出；
    // 短文字弹窗自然收窄贴合文字，信息量大的弹窗（进度条/文件列表）自然撑开，
    // 不再为不同弹窗硬编码固定档位。
    final cap = math.min(maxWidth, math.max(240.0, screenW - 48.0));
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          constraints: BoxConstraints(minWidth: 240, maxWidth: cap),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          decoration: BoxDecoration(
            color: const Color(0xE61B2434),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x26FFFFFF)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 40,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              content,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var i = 0; i < actions.length; i++)
                      Padding(
                        padding: EdgeInsets.only(left: i == 0 ? 0 : 8),
                        child: actions[i],
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 统一的玻璃弹窗入口：内置入场（缩放+淡入）与出场（缩放+淡出）动画，
/// 用 [material.showGeneralDialog] 借助正反向过渡实现，取代无出场动画的 `showDialog`。
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return material.showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: '',
    barrierColor: const Color(0x8A000000),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, animation, secondaryAnimation) =>
        Center(child: builder(dialogContext)),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return Opacity(
        opacity: curved.value,
        child: Transform.scale(
          scale: 0.92 + 0.08 * curved.value,
          alignment: Alignment.center,
          child: child,
        ),
      );
    },
  );
}