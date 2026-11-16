import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/models/device_info.dart';
import 'package:mysend/models/sync_mapping.dart';
import 'package:mysend/services/local_index_service.dart';
import 'package:mysend/services/sync_engine.dart';
import 'package:mysend/services/transfer/local_transfer_server.dart';
import 'package:mysend/services/transfer/peer_client.dart';
import 'package:mysend/storage/config_repository.dart';
import 'transfer_test_support.dart';
import 'package:mysend/services/transfer/transfer_identity.dart';

void main() {
  for (final kind in ['small', 'small-latency', 'large']) {
    test('BENCH $kind', () async {
      final root = await Directory.systemTemp.createTemp('mysend_bench_');
      final mapping = SyncMapping(
          id: 'm',
          name: 'test',
          sourcePath: '${root.path}/src',
          destPath: '${root.path}/dst');
      await Directory(mapping.sourcePath).create();
      await Directory(mapping.destPath).create();
      if (kind != 'large') {
        for (var i = 0; i < 200; i++) {
          await File('${mapping.sourcePath}/$i.bin')
              .writeAsBytes(Uint8List(8192));
        }
      } else {
        await File('${mapping.sourcePath}/large.bin')
            .writeAsBytes(Uint8List(64 * 1024 * 1024));
      }
      final config = ConfigRepository();
      config.config.mappings.add(mapping);
      final identity = await TransferIdentity.generate();
      final server = LocalTransferServer(
          identity: identity,
          preferredPort: 0,
          config: config,
          isSender: false,
          session: 's',
          onPeerPaired: (_, __) {},
          onSyncLog: (_) async {},
          onDisconnect: (_) {});
      final localConfig = ConfigRepository();
      localConfig.config.deviceId = 'client';
      final local = LocalTransferServer(
          identity: identity,
          preferredPort: 0,
          config: localConfig,
          isSender: true,
          session: 'c',
          onPeerPaired: (_, __) {},
          onSyncLog: (_) async {},
          onDisconnect: (_) {});
      await server.start();
      await local.start();
      final link = kind == 'small-latency'
          ? await DelayedTransferLink.start(server.port)
          : null;
      final client = PeerClient(
          identity: identity,
          peer: PeerDevice(
              fingerprint: identity.fingerprint,
              id: config.config.deviceId,
              name: 's',
              form: 'phone',
              session: 's',
              address: '127.0.0.1',
              port: link?.port ?? server.port,
              lastSeen: DateTime.now()),
          token: server.issueTokenFor('client'),
          session: 'c',
          deviceId: 'client',
          deviceName: 'c',
          role: 'pc',
          form: 'desktop',
          localPort: local.port);
      try {
        final index = await LocalIndexService.scan(mapping.sourcePath);
        final plan = SyncEngine.computeBidirectionalPlan(
            mapping: mapping, local: index, remote: {});
        final watch = Stopwatch()..start();
        final result = await SyncEngine.runBidirectional(
            mapping: mapping,
            client: client,
            localServer: local,
            plan: plan,
            localRoot: mapping.sourcePath,
            onProgress: (_, __, ___, ____) {});
        watch.stop();
        print(
            'BENCH $kind ${watch.elapsedMilliseconds} ms ${(plan.totalBytes / 1048576 / (watch.elapsedMicroseconds / 1e6)).toStringAsFixed(1)} MiB/s');
        expect(result.failed, 0);
        expect(result.pushed, index.length);
      } finally {
        client.close();
        await link?.close();
        await local.stop();
        await server.stop();
        await root.delete(recursive: true);
      }
    });
  }
}
