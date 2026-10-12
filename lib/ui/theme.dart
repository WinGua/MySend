import 'package:fluent_ui/fluent_ui.dart';

/// Win11 磨砂玻璃主题。
class AppTheme {
  AppTheme._();

  static FluentThemeData dark() => FluentThemeData(
        brightness: Brightness.dark,
        accentColor: Colors.blue,
        // 半透明背景，透出窗口背后的 Mica/Acrylic 磨砂效果。
        scaffoldBackgroundColor: const Color(0xB31E1E1E),
      );
}
