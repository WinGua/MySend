import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/main.dart' as app;
import 'package:mysend/app.dart';
import 'package:mysend/app_scope.dart';

void main() {
  testWidgets('配置或服务初始化未完成时仍显示首帧，失败时显示可重试错误', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final directory = Completer<String?>();
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => directory.future);
    final launched = app.main();
    try {
      await tester.pump();
      expect(find.byType(MySendApp), findsOneWidget);
      expect(find.textContaining('正在启动'), findsWidgets);
    } finally {
      directory.completeError(
          PlatformException(code: 'startup-test', message: '模拟应用目录不可用'));
      await launched.catchError((_) {});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('重试'), findsOneWidget);
      expect(find.textContaining('模拟应用目录不可用'), findsWidgets);
      await scope.stopServices();
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
}
