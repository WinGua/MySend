import 'dart:async';
import 'dart:io';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:mysend/ui/startup_gate.dart';
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
  testWidgets('目录拒绝访问时自动请求一次提权，取消后重试不反复弹窗', (tester) async {
    const channel = MethodChannel('mysend/windows_privileges');
    var requests = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      expect(call.method, 'isElevated');
      return false;
    });
    await tester.pumpWidget(FluentApp(
        home: StartupGate(
      initialize: (_) async {
        throw const PathAccessException(
            'WinGua', OSError('Access denied', 5), 'Creation failed');
      },
      restartAsAdministrator: () async {
        requests++;
        return false;
      },
      child: const Text('ready'),
    )));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.textContaining('已取消管理员授权'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests, 1, reason: '取消授权后不能因重新检查目录而重复弹 UAC');
    expect(find.text('以管理员身份重新启动'), findsOneWidget);
    await tester.tap(find.text('以管理员身份重新启动'));
    await tester.pumpAndSettle();
    expect(requests, 2, reason: '用户仍可主动再次请求管理员授权');
    expect(find.textContaining('已取消管理员授权'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  testWidgets('已有管理员权限时不自动请求或提供重复提权', (tester) async {
    const channel = MethodChannel('mysend/windows_privileges');
    var requests = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      expect(call.method, 'isElevated');
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(FluentApp(
        home: StartupGate(
      initialize: (_) async {
        throw const PathAccessException(
            'WinGua', OSError('Access denied', 5), 'Creation failed');
      },
      restartAsAdministrator: () async {
        requests++;
        return true;
      },
      child: const Text('ready'),
    )));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.textContaining('当前已是管理员权限'), findsOneWidget);
    expect(find.text('以管理员身份重新启动'), findsNothing);
  });

  testWidgets('其他启动错误不触发管理员权限查询或 UAC', (tester) async {
    const channel = MethodChannel('mysend/windows_privileges');
    var queries = 0;
    var requests = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (_) async {
      queries++;
      return false;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(FluentApp(
        home: StartupGate(
      initialize: (_) async {
        throw const FormatException('配置格式错误');
      },
      restartAsAdministrator: () async {
        requests++;
        return true;
      },
      child: const Text('ready'),
    )));
    await tester.pumpAndSettle();
    expect(queries, 0);
    expect(requests, 0);
    expect(find.text('以管理员身份重新启动'), findsNothing);
    expect(find.textContaining('配置格式错误'), findsWidgets);
  });

  testWidgets('权限不足会自动发起管理员重启，成功后不再重复触发', (tester) async {
    const channel = MethodChannel('mysend/windows_privileges');
    var requests = 0;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(FluentApp(
        home: StartupGate(
      initialize: (_) async {
        throw const PathAccessException(
            'WinGua', OSError('Access denied', 5), 'Creation failed');
      },
      restartAsAdministrator: () async {
        requests++;
        return true;
      },
      child: const Text('ready'),
    )));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('管理员实例已启动'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(requests, 1);
  });
}
