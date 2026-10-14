import 'dart:ui' show ImageFilter;

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