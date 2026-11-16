import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/app_scope.dart';
import 'package:mysend/core/utils.dart';
import 'package:mysend/models/device_info.dart';
import 'package:mysend/models/file_entry.dart';
import 'package:mysend/models/sync_mapping.dart';
import 'package:mysend/services/transfer/local_transfer_server.dart';
import 'package:mysend/services/transfer/transfer_identity.dart';
import 'package:mysend/storage/config_repository.dart';
import 'transfer_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('停止服务会取消已经创建的主动下载客户端，而非只关闭监听端口', () async {
    final root = await Directory.systemTemp.createTemp('mysend_cancel_scope_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => root.path);
    final app = AppScope();
    final source = Directory('${root.path}/remote');
    await source.create();
    final file = File('${source.path}/large.bin');
    await file.writeAsBytes(Uint8List(16 * 1024 * 1024));
    final mapping = SyncMapping(
        id: 'music',
        name: 'music',
        sourcePath: source.path,
        destPath: source.path);
    final config = ConfigRepository();
    config.config.deviceId = 'remote';
    config.config.mappings.add(mapping);
    final server = LocalTransferServer(
        identity: await TransferIdentity.generate(),
        preferredPort: 0,
        config: config,
        isSender: !isSender,
        session: 'remote',
        onPeerPaired: (_, __) {},
        onSyncLog: (_) async {},
        onDisconnect: (_) {});
    await server.start();
    final link =
        await DelayedTransferLink.start(server.port, maxChunkBytes: 16 * 1024);
    app.config.config.transferPort = 0;
    await app.startServices();
    final peer = PeerDevice(
        id: config.config.deviceId,
        name: 'remote',
        form: isSender ? 'phone' : 'desktop',
        session: 'remote',
        address: '127.0.0.1',
        port: link.port,
        fingerprint: server.identity.fingerprint,
        lastSeen: DateTime.now());
    expect(await app.connect(peer), isTrue);
    final client = app.clientFor(peer);
    final target = File('${root.path}/partial');
    final finished = Completer<void>();
    final transfer = client.withSyncSession(app.server!, () async {
      await client.download(
          mapping,
          FileEntry(
              relativePath: 'large.bin', size: await file.length(), mtimeMs: 1),
          target);
    }).then<void>((_) {
      finished.complete();
    }, onError: (Object _) {
      finished.complete();
    });
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while ((!await target.exists() || await target.length() == 0) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await target.length(), greaterThan(0));
      expect(finished.isCompleted, isFalse);
      await app.stopServices().timeout(const Duration(seconds: 1));
      final stopped = await Future.any([
        finished.future.then((_) => true),
        Future<bool>.delayed(const Duration(seconds: 1), () => false)
      ]);
      expect(stopped, isTrue, reason: '停止服务后，文件连接必须立即中断，不能继续传输');
    } finally {
      client.close();
      await transfer;
      await app.stopServices();
      await server.stop();
      await link.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
