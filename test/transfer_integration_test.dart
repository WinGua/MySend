import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:mysend/models/device_info.dart';
import 'package:mysend/models/sync_mapping.dart';
import 'package:mysend/services/local_index_service.dart';
import 'package:mysend/services/sync_engine.dart';
import 'package:mysend/services/transfer/local_transfer_server.dart';
import 'package:mysend/services/transfer/peer_client.dart';
import 'package:mysend/storage/config_repository.dart';
import 'package:mysend/services/transfer/transfer_identity.dart';
import 'package:mysend/services/transfer/protocol.dart';
import 'package:mysend/services/transfer/part_store.dart';
import 'package:mysend/models/file_entry.dart';
import 'package:mysend/models/sync_plan.dart';
import 'package:mysend/app_scope.dart';
import 'package:mysend/models/remote_sync_state.dart';

void main() {
  late TransferIdentity identity;
  late TransferIdentity localIdentity;
  setUpAll(() async {
    identity = await TransferIdentity.generate();
    localIdentity = await TransferIdentity.generate();
  });
  late Directory root;
  late LocalTransferServer localServer;
  late LocalTransferServer server;
  late PeerClient client;
  late SyncMapping mapping;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mysend_transfer_');
    mapping = SyncMapping(
        id: 'm',
        name: 'test',
        sourcePath: '${root.path}/source',
        destPath: '${root.path}/dest');
    await Directory(mapping.sourcePath).create();
    await Directory(mapping.destPath).create();
    final config = ConfigRepository();
    config.config.mappings.add(mapping);
    server = LocalTransferServer(
        identity: identity,
        preferredPort: 0,
        config: config,
        isSender: false,
        session: 'server',
        onPairRequest: (_) async => true,
        onPeerPaired: (_, __) {},
        onSyncLog: (_) async {},
        onDisconnect: (_) {});
    await server.start();
    final localConfig = ConfigRepository();
    localConfig.config.deviceId = 'client';
    localConfig.config.mappings.add(mapping);
    localServer = LocalTransferServer(
        identity: localIdentity,
        preferredPort: 0,
        config: localConfig,
        isSender: true,
        session: 'client',
        onPairRequest: (_) async => true,
        onPeerPaired: (_, __) {},
        onSyncLog: (_) async {},
        onDisconnect: (_) {});
    await localServer.start();
    client = PeerClient(
        identity: localIdentity,
        peer: PeerDevice(
            fingerprint: identity.fingerprint,
            id: config.config.deviceId,
            name: 'server',
            form: 'phone',
            session: 'server',
            address: '127.0.0.1',
            port: server.port,
            lastSeen: DateTime.now()),
        token: server.issueTokenFor('client'),
        session: 'client',
        deviceId: 'client',
        deviceName: 'client',
        role: 'pc',
        form: 'desktop',
        localPort: 0);
  });

  tearDown(() async {
    client.close();
    await server.stop();
    await localServer.stop();
    await root.delete(recursive: true);
  });

  test('首次配对必须确认，停止服务会结束等待且不信任该身份', () async {
    var paired = false;
    final requested = Completer<void>();
    final decision = Completer<bool>();
    final promptServer = LocalTransferServer(
      identity: identity,
      preferredPort: 0,
      config: ConfigRepository(),
      isSender: false,
      session: 'prompt-server',
      onPairRequest: (_) {
        requested.complete();
        return decision.future;
      },
      onPeerPaired: (_, __) {
        paired = true;
      },
      onSyncLog: (_) async {},
      onDisconnect: (_) {},
    );
    await promptServer.start();
    final requester = PeerClient(
        identity: localIdentity,
        peer: client.peer.copyWith(port: promptServer.port),
        token: '',
        session: 'client',
        deviceId: 'client',
        deviceName: 'client',
        role: 'pc',
        form: 'desktop',
        localPort: 0);
    try {
      final pending = requester
          .pair()
          .then<Object>((value) => value, onError: (Object error) => error);
      await requested.future.timeout(const Duration(seconds: 2));
      expect(paired, isFalse);
      await promptServer.stop().timeout(const Duration(seconds: 2));
      await pending.timeout(const Duration(seconds: 2));
      expect(paired, isFalse);
    } finally {
      if (!decision.isCompleted) decision.complete(false);
      requester.close();
      await promptServer.stop();
    }
  });

  test('公开设备 ID 和指纹不能伪造已配对身份或替换有效 token', () async {
    server.config.config.trustedFingerprints['client'] =
        localIdentity.fingerprint;
    final http = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (cert, _, __) =>
          sha256.convert(cert.der).toString() == identity.fingerprint;
    try {
      final request = await http
          .postUrl(Uri.parse('https://127.0.0.1:${server.port}/v2/pair'));
      final bytes = utf8.encode(jsonEncode({
        ...PeerDevice.describe(
            id: 'client',
            name: 'forged',
            role: 'pc',
            form: 'desktop',
            port: 0,
            session: 'forged',
            fingerprint: localIdentity.fingerprint),
      }));
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 401, reason: '公开指纹不是持有私钥的证明');
      await client.fetchIndex(mapping.name);
    } finally {
      http.close(force: true);
    }
  });

  test('取消控制验证任务所有者，活动文件退出前不开放新任务', () async {
    const task = 'cancel-task';
    expect(server.sessions.acquire('client', task), isTrue);
    expect(server.sessions.enter('client', task), isTrue);
    final stranger = PeerClient(
        identity: localIdentity,
        peer: client.peer,
        token: server.issueTokenFor('stranger'),
        session: 'stranger',
        deviceId: 'stranger',
        deviceName: 'stranger',
        role: 'pc',
        form: 'desktop',
        localPort: 0);
    try {
      await expectLater(stranger.requestCancellation(task),
          throwsA(isA<TransferException>()));
      expect(server.sessions.matches('client', task), isTrue);
      await client.requestCancellation(task);
      expect(server.sessions.matches('client', task), isFalse);
      expect(server.sessions.acquire('stranger', 'new-task'), isFalse);
      server.sessions.leave();
      expect(server.sessions.acquire('stranger', 'new-task'), isTrue);
    } finally {
      stranger.close();
    }
  });

  test('接收端取消会关闭正在等待上传数据的文件连接', () async {
    const task = 'slow-upload';
    expect(server.sessions.acquire('client', task), isTrue);
    final http = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (cert, _, __) =>
          sha256.convert(cert.der).toString() == identity.fingerprint;
    final req = await http.postUrl(Uri.parse(
        'https://127.0.0.1:${server.port}/v2/upload?name=test&path=partial.bin&size=1048576&mtime=1'));
    req.headers.set('X-MySend-Token', client.token);
    req.headers.set('X-MySend-Sync', task);
    req.contentLength = 1048576;
    req.bufferOutput = false;
    req.add(Uint8List(768 * 1024));
    await req.flush();
    final part = PartStore.partFile(mapping.destPath, 'partial.bin');
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while ((!await part.exists() || await part.length() == 0) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await part.length(), greaterThan(0));
      await client
          .requestCancellation(task)
          .timeout(const Duration(seconds: 1));
      expect(server.sessions.busy, isFalse);
      expect(await File('${mapping.destPath}/partial.bin').exists(), isFalse);
      expect(await part.length(), lessThan(1048576));
    } finally {
      req.abort();
      http.close(force: true);
    }
  });

  test('传输端口拒绝明文 HTTP', () async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    addTearDown(() => http.close(force: true));
    await expectLater(() async {
      final req = await http
          .getUrl(Uri.parse('http://127.0.0.1:${server.port}/v2/hello'));
      final res = await req.close().timeout(const Duration(seconds: 2));
      await res.drain<void>();
    }, throwsA(anything));
  });

  test('同时申请同步会话只能成功一个', () async {
    final http = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (cert, _, __) =>
          sha256.convert(cert.der).toString() == identity.fingerprint;
    addTearDown(() => http.close(force: true));
    final token = server.issueTokenFor('lock-client');
    final statuses = await Future.wait(List.generate(2, (i) async {
      final req = await http.postUrl(Uri.parse(
          'https://127.0.0.1:${server.port}/v2/sync/acquire?task=task-$i'));
      req.headers.set('X-MySend-Token', token);
      req.contentLength = 0;
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }));
    expect(statuses..sort(), [200, 409]);
  });

  test('同一分片并发上传不可重复写入', () async {
    final file = File('${mapping.sourcePath}/large.bin');
    await file.writeAsBytes(Uint8List(4 * 1024 * 1024));
    final outcomes = await client.withSyncSession(
        localServer,
        () => Future.wait(List.generate(2, (_) async {
              try {
                await client.upload(mapping, 'large.bin', file, mtimeMs: 1);
                return 'ok';
              } catch (e) {
                return e.toString();
              }
            })));
    expect(outcomes.where((e) => e == 'ok').length, 1);
    expect(
        await File('${mapping.destPath}/large.bin').length(), 4 * 1024 * 1024);
  });

  test('证书指纹不符时在发送请求前拒绝连接', () async {
    var requests = 0;
    final listener =
        await HttpServer.bindSecure('127.0.0.1', 0, identity.context);
    listener.listen((req) {
      requests++;
      writeJson(req, {'ok': true});
    });
    addTearDown(() => listener.close(force: true));
    final wrong = PeerClient(
        identity: localIdentity,
        peer: client.peer.copyWith(port: listener.port, fingerprint: '0' * 64),
        session: 'client',
        deviceId: 'client',
        deviceName: 'client',
        role: 'pc',
        form: 'desktop',
        localPort: localServer.port);
    addTearDown(wrong.close);
    await expectLater(
        wrong.fetchIndex('test'), throwsA(isA<HandshakeException>()));
    expect(requests, 0);
  });

  test('顺序控制请求复用同一 TLS 连接', () async {
    final ports = <int>{};
    final listener =
        await HttpServer.bindSecure('127.0.0.1', 0, identity.context);
    listener.listen((req) {
      ports.add(req.connectionInfo!.remotePort);
      writeJson(req, {'ok': true, 'files': []});
    });
    addTearDown(() => listener.close(force: true));
    final pooled = PeerClient(
        identity: localIdentity,
        peer: client.peer.copyWith(port: listener.port),
        session: 'client',
        deviceId: 'client',
        deviceName: 'client',
        role: 'pc',
        form: 'desktop',
        localPort: localServer.port);
    addTearDown(pooled.close);
    for (var i = 0; i < 20; i++) {
      await pooled.fetchIndex('test');
    }
    expect(ports.length, 1);
  });

  test('双端同时点击只运行一个任务且结束后可重新申请', () async {
    final reverse = PeerClient(
        identity: identity,
        peer: PeerDevice(
            id: 'client',
            fingerprint: localIdentity.fingerprint,
            name: 'client',
            form: 'desktop',
            session: 'client',
            address: '127.0.0.1',
            port: localServer.port,
            lastSeen: DateTime.now()),
        token: localServer.issueTokenFor(server.config.config.deviceId),
        session: 'server',
        deviceId: server.config.config.deviceId,
        deviceName: 'server',
        role: 'android',
        form: 'phone',
        localPort: server.port);
    addTearDown(reverse.close);
    for (var i = 0; i < 20; i++) {
      var runs = 0;
      final entered = Completer<void>();
      final rejected = Completer<void>();
      final release = Completer<void>();
      Future<String> run(PeerClient c, LocalTransferServer local) async {
        try {
          await c.withSyncSession(local, () async {
            runs++;
            entered.complete();
            await release.future;
          });
          return 'ok';
        } on TransferException catch (e) {
          if (e.code != 'BUSY') rethrow;
          rejected.complete();
          return 'busy';
        }
      }

      final outcomes =
          Future.wait([run(client, localServer), run(reverse, server)]);
      await entered.future;
      await rejected.future;
      release.complete();
      expect((await outcomes)..sort(), ['busy', 'ok']);
      expect(runs, 1);
      expect(server.busy, isFalse);
      expect(localServer.busy, isFalse);
    }
  });

  test('TLS 配对交换 token，固定身份改变时拒绝重新配对', () async {
    final result = await client.pair(
        tokenToOffer: localServer.issueTokenFor(server.config.config.deviceId));
    expect(result.token, isNotEmpty);
    expect(result.session, 'server');
    server.config.config.trustedFingerprints['client'] = '0' * 64;
    await expectLater(
        client.pair(),
        throwsA(isA<TransferException>()
            .having((e) => e.code, 'code', 'CERT_CHANGED')));
  });

  test('任务异常会释放两端会话', () async {
    await expectLater(
        client.withSyncSession(localServer, () async {
          throw StateError('test failure');
        }),
        throwsStateError);
    expect(localServer.busy, isFalse);
    expect(server.busy, isFalse);
    await client.withSyncSession(localServer, () async {});
  });

  test('上传和下载均能从已有分片续传，进度只累计新字节', () async {
    final sent = List.generate(100003, (i) => i % 251);
    final received = List.generate(110001, (i) => (i * 3) % 251);
    final src = File('${mapping.sourcePath}/send.bin');
    final remote = File('${mapping.destPath}/receive.bin');
    await src.writeAsBytes(sent);
    await remote.writeAsBytes(received);
    final localIndex = await LocalIndexService.scan(mapping.sourcePath);
    final remoteIndex = await LocalIndexService.scan(mapping.destPath);
    Future<void> seed(
        String root, FileEntry entry, List<int> bytes, int count) async {
      await PartStore.writeMeta(
          root,
          entry.relativePath,
          PartMeta(
              path: entry.relativePath,
              size: entry.size,
              mtime: entry.mtimeMs));
      await PartStore.partFile(root, entry.relativePath)
          .writeAsBytes(bytes.sublist(0, count));
    }

    await seed(mapping.destPath, localIndex['send.bin']!, sent, 1234);
    await seed(mapping.sourcePath, remoteIndex['receive.bin']!, received, 4321);
    var transferred = 0;
    final result = await SyncEngine.runBidirectional(
        mapping: mapping,
        client: client,
        localServer: localServer,
        plan: SyncEngine.computeBidirectionalPlan(
            mapping: mapping, local: localIndex, remote: remoteIndex),
        localRoot: mapping.sourcePath,
        onTransferBytes: (bytes) => transferred += bytes,
        onProgress: (_, __, ___, ____) {});
    expect(result.failed, 0);
    expect(transferred, sent.length + received.length - 1234 - 4321);
    expect(await File('${mapping.destPath}/send.bin').readAsBytes(), sent);
    expect(await File('${mapping.sourcePath}/receive.bin').readAsBytes(),
        received);
    expect(await PartStore.partFile(mapping.destPath, 'send.bin').exists(),
        isFalse);
    expect(await PartStore.partFile(mapping.sourcePath, 'receive.bin').exists(),
        isFalse);
  });

  test('旧对比计划不会覆盖已存在文件，支持空文件', () async {
    await File('${mapping.sourcePath}/keep.txt').writeAsString('keep local');
    await File('${mapping.destPath}/keep.txt').writeAsString('keep remote');
    await File('${mapping.sourcePath}/empty.bin').writeAsBytes([]);
    await File('${mapping.destPath}/remote-empty.bin').writeAsBytes([]);
    final result = await SyncEngine.runBidirectional(
        mapping: mapping,
        client: client,
        localServer: localServer,
        plan: SyncPlan(
            mappingId: mapping.id,
            mappingName: mapping.name,
            toPush: const [],
            toPull: const [
              FileEntry(relativePath: 'keep.txt', size: 11, mtimeMs: 0)
            ],
            skippedCount: 0),
        localRoot: mapping.sourcePath,
        onProgress: (_, __, ___, ____) {});
    expect(result.failed, 0);
    expect(result.pushed, 1);
    expect(result.pulled, 1);
    expect(await File('${mapping.sourcePath}/keep.txt').readAsString(),
        'keep local');
    expect(await File('${mapping.destPath}/keep.txt').readAsString(),
        'keep remote');
    expect(await File('${mapping.destPath}/empty.bin').length(), 0);
    expect(await File('${mapping.sourcePath}/remote-empty.bin').length(), 0);
  });

  test('四条文件连接占满时仍能续租', () async {
    final renewed = Completer<void>();
    final release = Completer<void>();
    var uploads = 0;
    final listener =
        await HttpServer.bindSecure('127.0.0.1', 0, identity.context);
    listener.listen((req) async {
      if (req.uri.path == '/v2/upload') {
        uploads++;
        await release.future;
        await req.drain<void>();
      } else if (req.uri.path == '/v2/sync/renew' && !renewed.isCompleted) {
        renewed.complete();
      }
      writeJson(req, {'ok': true});
    });
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await listener.close(force: true);
    });
    final sending = PeerClient(
        identity: localIdentity,
        peer: client.peer.copyWith(port: listener.port),
        token: 'test',
        session: 'client',
        deviceId: 'client',
        deviceName: 'client',
        role: 'pc',
        form: 'desktop',
        localPort: localServer.port);
    addTearDown(sending.close);
    final file = File('${mapping.sourcePath}/test.bin');
    await file.writeAsBytes(Uint8List(8 * 1024 * 1024));
    final task = sending.withSyncSession(
        localServer,
        () => Future.wait(List.generate(
            4, (i) => sending.upload(mapping, '$i.bin', file, mtimeMs: 1))));
    try {
      await renewed.future.timeout(const Duration(seconds: 20));
      expect(uploads, 4);
    } finally {
      release.complete();
      await task;
    }
  });

  test('参与同步时拒绝重新连接，并保留正在使用的 token', () async {
    final app = AppScope();
    app.server = server;
    expect(server.sessions.acquire('client', 'running'), isTrue);
    try {
      expect(await app.connect(client.peer), isFalse);
      expect(app.connectionError, contains('同步'));
    } finally {
      server.sessions.release('client', 'running');
    }
    expect(await client.fetchIndex(mapping.name), isEmpty);
    app.dispose();
  });

  test('停止服务须等已接收的请求结束，避免重启后旧任务继续写入', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final config = ConfigRepository();
    final stoppingServer = LocalTransferServer(
        identity: identity,
        preferredPort: 0,
        config: config,
        isSender: false,
        session: 'stop-test',
        onPairRequest: (_) async => true,
        onPeerPaired: (_, __) {},
        onSyncLog: (_) async {
          entered.complete();
          await release.future;
        },
        onDisconnect: (_) {});
    await stoppingServer.start();
    final sender = PeerClient(
        identity: localIdentity,
        peer: client.peer.copyWith(port: stoppingServer.port),
        token: stoppingServer.issueTokenFor('client'),
        session: 'client',
        deviceId: 'client',
        deviceName: 'client',
        role: 'pc',
        form: 'desktop',
        localPort: localServer.port);
    final logging = sender.sendLog(SyncLogReport(
        mappingName: 'test', peerName: 'client', time: DateTime.now()));
    await entered.future;
    var stopped = false;
    final stopping = stoppingServer.stop().then((_) => stopped = true);
    try {
      await expectLater(logging, throwsA(anything));
      expect(stopped, isFalse);
    } finally {
      release.complete();
      await stopping;
      sender.close();
    }
  });

  test('对端收到准备、真实双向进度和镜像结果，正常释放不变成失败', () async {
    final states = <RemoteSyncState>[];
    server.remoteSync.addListener(() {
      if (server.remoteSync.value != null) states.add(server.remoteSync.value!);
    });
    await File('${mapping.sourcePath}/send.bin')
        .writeAsBytes(Uint8List(600001));
    await File('${mapping.destPath}/receive.bin')
        .writeAsBytes(Uint8List(700003));
    final plan = SyncEngine.computeBidirectionalPlan(
        mapping: mapping,
        local: await LocalIndexService.scan(mapping.sourcePath),
        remote: await LocalIndexService.scan(mapping.destPath));
    final result = await SyncEngine.runBidirectional(
        mapping: mapping,
        client: client,
        localServer: localServer,
        plan: plan,
        localRoot: mapping.sourcePath,
        onProgress: (_, __, ___, ____) {});
    expect(result.success, isTrue);
    expect(states.first.preparing, isTrue);
    expect(states.first.mappingName, mapping.name);
    expect(
        states.any((s) => s.currentName == 'send.bin' && !s.sending), isTrue);
    expect(
        states.any((s) => s.currentName == 'receive.bin' && s.sending), isTrue);
    final remote = server.remoteSync.value!;
    expect(remote.finished, isTrue);
    expect(remote.error, isNull);
    expect(remote.sentCount, 1);
    expect(remote.receivedCount, 1);
    expect(remote.transferredBytes, 1300004);
    expect(remote.sentBytes, 700003);
    expect(remote.receivedBytes, 600001);
  });

  test('没有同步会话不能通知对端弹窗，异常释放结束接收端进度', () async {
    await expectLater(
        client.sendSyncStatus({'phase': 'start'}), throwsStateError);
    expect(server.remoteSync.value, isNull);
    await expectLater(
        client.withSyncSession(localServer, () async {
          await client.sendSyncStatus({
            'phase': 'start',
            'name': mapping.name,
            'peer': 'client',
            'total': 1
          });
          throw StateError('interrupted');
        }),
        throwsStateError);
    expect(server.remoteSync.value!.finished, isTrue);
    expect(server.remoteSync.value!.error, isNotNull);
  });

  test('传输测速及双向内容校验', () async {
    const count = 200;
    for (var i = 0; i < count; i++) {
      await File('${mapping.sourcePath}/small-$i.bin')
          .writeAsBytes(List.filled(8192, i % 256));
    }
    await File('${mapping.sourcePath}/large.bin')
        .writeAsBytes(Uint8List(64 * 1024 * 1024));
    await File('${mapping.destPath}/remote.txt').writeAsString('remote');
    final local = await LocalIndexService.scan(mapping.sourcePath);
    final remote = {
      for (final e in await client.fetchIndex(mapping.name)) e.relativePath: e
    };
    final plan = SyncEngine.computeBidirectionalPlan(
        mapping: mapping, local: local, remote: remote);
    final watch = Stopwatch()..start();
    final result = await SyncEngine.runBidirectional(
        mapping: mapping,
        client: client,
        localServer: localServer,
        plan: plan,
        localRoot: mapping.sourcePath,
        onProgress: (_, __, ___, ____) {});
    watch.stop();
    // ignore: avoid_print
    print(
        'BENCH 200x8KiB+64MiB: ${watch.elapsedMilliseconds} ms; ${(plan.totalBytes / 1048576 / (watch.elapsedMicroseconds / 1e6)).toStringAsFixed(1)} MiB/s');
    expect(result.failed, 0);
    expect(result.pushed, 201);
    expect(result.pulled, 1);
    expect(await File('${mapping.sourcePath}/remote.txt').readAsString(),
        'remote');
    for (final e in local.values) {
      final bytes =
          await File('${mapping.destPath}/${e.relativePath}').readAsBytes();
      expect(
          sha256.convert(bytes),
          sha256.convert(await File('${mapping.sourcePath}/${e.relativePath}')
              .readAsBytes()));
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
