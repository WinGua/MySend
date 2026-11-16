// Same disk streams and file; only the TLS data plane changes.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:mysend/services/transfer/native_transport.dart';
import 'package:mysend/services/transfer/transfer_identity.dart';
import 'package:mysend/services/transfer/buffered_stream.dart';

Future<void> main(List<String> args) async {
  final api = NativeTransport(DynamicLibrary.open(args.single));
  final root = await Directory.systemTemp.createTemp('mysend_native_bench_');
  try {
    final source = File('${root.path}/source.bin');
    final content = Uint8List(64 * 1024 * 1024);
    for (var i = 0; i < content.length; i++) {
      content[i] = i % 251;
    }
    await source.writeAsBytes(content);
    final expected = sha256.convert(content).toString();
    final identity = await TransferIdentity.generate();
    for (final native in [false, true]) {
      final server = native
          ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
          : await HttpServer.bindSecure(
              InternetAddress.loopbackIPv4, 0, identity.context);
      final front = native
          ? api.server(
              identity.certificate, identity.privateKey, server.port, 0)
          : null;
      final outgoing = native
          ? api.client('127.0.0.1', front!.port, identity.fingerprint)
          : null;
      final target = File('${root.path}/target.bin');
      server.listen((req) async {
        final sink = target.openWrite();
        try {
          await sink.addStream(bufferedTransferStream(req));
          await sink.flush();
          await sink.close();
          req.response.contentLength = 2;
          req.response.write('ok');
          await req.response.close();
        } catch (error) {
          await sink.close();
          req.response.statusCode = 500;
          await req.response.close();
        }
      });
      final client = native
          ? HttpClient()
          : HttpClient(context: SecurityContext(withTrustedRoots: false));
      client.findProxy = (_) => 'DIRECT';
      client.badCertificateCallback = (cert, host, port) =>
          host == '127.0.0.1' &&
          port == server.port &&
          sha256.convert(cert.der).toString() == identity.fingerprint;
      try {
        final samples = <int>[];
        for (var i = 0; i < 3; i++) {
          final watch = Stopwatch()..start();
          final req = await client.postUrl(Uri.parse(
              '${native ? 'http' : 'https'}://127.0.0.1:${outgoing?.port ?? server.port}/upload'));
          req.contentLength = content.length;
          await req.addStream(readTransferFile(source, end: content.length));
          final res = await req.close();
          final body = await utf8.decoder.bind(res).join();
          watch.stop();
          if (res.statusCode != 200 ||
              body != 'ok' ||
              sha256.convert(await target.readAsBytes()).toString() !=
                  expected) {
            throw StateError(
                'Incomplete transfer: ${front?.error} / ${outgoing?.error}');
          }
          samples.add(watch.elapsedMicroseconds);
        }
        final ordered = samples.toList()..sort();
        print(
            '${native ? 'Native rustls' : 'Dart TLS'} 64 MiB: ${samples.map((us) => (us / 1000).toStringAsFixed(1)).join(', ')} ms; median ${(64 / (ordered[1] / 1e6)).toStringAsFixed(1)} MiB/s; SHA-256 OK');
      } finally {
        client.close(force: true);
        outgoing?.close();
        front?.close();
        await server.close(force: true);
      }
    }
  } finally {
    await root.delete(recursive: true);
  }
}
