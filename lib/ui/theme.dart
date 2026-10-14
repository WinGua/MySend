import 'package:fluent_ui/fluent_ui.dart';

/// Win11 磨砂玻璃主题。
class AppTheme {
  AppTheme._();

  static FluentThemeData dark() => FluentThemeData(
        brightness: Brightness.dark,
        accentColor: const Color(0xFF4A9EFF),
        // 背景交给 shell 里的 GradientBackground + 毛玻璃卡片，
        // 此处设为透明，避免遮挡渐变底。
        scaffoldBackgroundColor: const Color(0x00000000),
      );
}
