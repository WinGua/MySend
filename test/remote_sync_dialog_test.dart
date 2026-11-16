import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/models/remote_sync_state.dart';
import 'package:mysend/models/file_entry.dart';
import 'package:mysend/services/sync_engine.dart';
import 'package:mysend/ui/theme.dart';
import 'package:mysend/ui/widgets/glass.dart';
import 'package:mysend/ui/widgets/remote_sync_dialog_host.dart';
import 'package:mysend/ui/widgets/sync_dialog.dart';
import 'package:mysend/services/transfer/peer_client.dart';

Future<void> capture(WidgetTester tester, String name) async {
  const destination = String.fromEnvironment('MYSEND_SCREENSHOT_DIR');
  if (destination.isEmpty) return;
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary = tester.firstRenderObject(find.byType(RepaintBoundary))
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$destination/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const fontPath = String.fromEnvironment('MYSEND_TEST_FONT');
FluentThemeData testTheme() => fontPath.isEmpty
    ? AppTheme.dark()
    : FluentThemeData(
        brightness: Brightness.dark,
        accentColor: Colors.blue,
        scaffoldBackgroundColor: const Color(0x00000000),
        fontFamily: 'MySendTest');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (fontPath.isNotEmpty) {
      final bytes = await File(fontPath).readAsBytes();
      final font = FontLoader('MySendTest')
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await font.load();
    }
  });
  testWidgets('本机发起的大文件也在完成前显示25%', (tester) async {
    final result = Completer<SyncResult>();
    await tester.pumpWidget(FluentApp(
        theme: testTheme(),
        home: SyncDialog(
            mappingName: '音乐',
            failures: const [],
            run: (_, onBytes, onDetails) async {
              onDetails(const SyncByteProgress(
                  .25,
                  1048576,
                  FileEntry(
                      relativePath: 'large.bin', size: 4194304, mtimeMs: 0),
                  SyncDirection.push,
                  done: 0,
                  total: 1));
              onBytes(1048576);
              return result.future;
            })));
    await tester.pump();
    expect(find.text('25% · 0/1 个文件'), findsOneWidget);
    result.complete(
        const SyncResult(pushed: 1, pulled: 0, pushFailed: 0, pullFailed: 0));
    await tester.pump();
  });
  testWidgets('单个大文件传到四分之一时显示25%而非0%', (tester) async {
    final progress = RemoteSyncTracker();
    addTearDown(progress.dispose);
    await tester.pumpWidget(FluentApp(
        theme: testTheme(),
        home:
            RemoteSyncDialogHost(progress: progress, child: const SizedBox())));
    progress.begin(task: 'bytes', peerName: '电脑', mappingName: '音乐', total: 1);
    progress.fileStarted('bytes', 'large.bin',
        sending: false, size: 4 * 1024 * 1024);
    progress.transferred('bytes', 1024 * 1024);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('25% · 0/1 个文件'), findsOneWidget);
    expect(progress.value!.done, 0);
    progress.finish('bytes', error: '测试结束');
    await tester.pump();
  });
  for (final size in [const Size(390, 844), const Size(1100, 720)]) {
    testWidgets('接收弹窗自动打开、刷新并保留结果 ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final progress = RemoteSyncTracker();
      addTearDown(progress.dispose);
      await tester.pumpWidget(RepaintBoundary(
          child: FluentApp(
              debugShowCheckedModeBanner: false,
              theme: testTheme(),
              home: RemoteSyncDialogHost(
                  progress: progress,
                  child: Stack(children: const [
                    Positioned.fill(child: GradientBackground()),
                    ScaffoldPage(content: Text('设置页面'))
                  ])))));
      expect(find.byType(SyncDialog), findsNothing);
      progress.begin(
          task: 'one', peerName: '我的电脑', mappingName: '音乐', total: 2);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SyncDialog), findsOneWidget);
      expect(find.text('准备同步 · 音乐'), findsOneWidget);
      expect(find.byType(GlassDialog), findsOneWidget);
      expect(find.text('关闭'), findsNothing);
      progress.planned('one', 2);
      progress.fileStarted('one', '专辑/song.flac', sending: false);
      progress.transferred('one', 1048576);
      progress.fileCompleted('one', 1048576, sending: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('同步中 · 音乐'), findsOneWidget);
      expect(find.text('当前：接收 song.flac'), findsOneWidget);
      expect(find.text('已发送 0 · 已接收 1'), findsOneWidget);
      expect(find.text('50% · 1/2 个文件'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(SyncDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'remote-sync-${size.width.toInt()}');
      progress.fileStarted('one', 'photo.jpg', sending: true);
      progress.transferred('one', 524288);
      progress.fileCompleted('one', 524288, sending: true);
      progress.finish('one', sentCount: 1, receivedCount: 1);
      await tester.pump();
      expect(find.text('同步完成'), findsOneWidget);
      expect(find.text('已发送 1 · 已接收 1'), findsOneWidget);
      await capture(tester, 'remote-sync-${size.width.toInt()}-complete');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(SyncDialog), findsNothing);
      progress.interrupted('one', '迟到通知');
      await tester.pump();
      expect(find.byType(SyncDialog), findsNothing);
    });
  }

  testWidgets('双方同时点击时接收进度替换本机忙碌窗口，不叠加两个弹窗', (tester) async {
    final progress = RemoteSyncTracker();
    addTearDown(progress.dispose);
    await tester.pumpWidget(FluentApp(
        theme: testTheme(),
        home: RemoteSyncDialogHost(
            progress: progress,
            child: Builder(
                builder: (context) => ScaffoldPage(
                        content: Button(
                      child: const Text('发起同步'),
                      onPressed: () => showGlassDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => SyncDialog(
                              mappingName: '音乐',
                              failures: const [],
                              incoming: progress,
                              run: (_, __, ___) async {
                                throw const TransferException(
                                    409, 'BUSY', '对端正在同步其他任务');
                              })),
                    ))))));
    await tester.tap(find.text('发起同步'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncDialog), findsOneWidget);
    expect(find.text('同步失败'), findsOneWidget);
    progress.begin(task: 'winner', peerName: '电脑', mappingName: '音乐', total: 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SyncDialog), findsOneWidget);
    expect(find.text('准备同步 · 音乐'), findsOneWidget);
    expect(find.text('同步失败'), findsNothing);
    progress.finish('winner');
    await tester.pump();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncDialog), findsNothing);
  });

  testWidgets('新任务复用弹窗，中断时显示失败并可关闭', (tester) async {
    final progress = RemoteSyncTracker();
    addTearDown(progress.dispose);
    await tester.pumpWidget(FluentApp(
        debugShowCheckedModeBanner: false,
        theme: testTheme(),
        home: RemoteSyncDialogHost(
            progress: progress,
            child: Stack(children: const [
              Positioned.fill(child: GradientBackground()),
              ScaffoldPage(content: Text('映射页面'))
            ]))));
    progress.begin(task: 'first', peerName: '手机', mappingName: '照片', total: 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    progress.finish('first');
    await tester.pump();
    progress.begin(task: 'second', peerName: '手机', mappingName: '文档', total: 3);
    await tester.pump();
    expect(find.byType(SyncDialog), findsOneWidget);
    expect(find.text('准备同步 · 文档'), findsOneWidget);
    progress.interrupted('second', '连接超时，同步已中断');
    await tester.pump();
    expect(find.text('同步失败'), findsOneWidget);
    expect(find.textContaining('连接超时'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncDialog), findsNothing);
    progress.begin(task: 'third', peerName: '手机', mappingName: '音乐', total: 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SyncDialog), findsOneWidget);
    progress.finish('third');
    await tester.pump();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });
}
