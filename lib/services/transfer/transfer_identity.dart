import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

/// 每次安装独立的自签名证书；证书指纹用作 TLS 对端身份。
class TransferIdentity {
  final String certificate;
  final String privateKey;

  const TransferIdentity(this.certificate, this.privateKey);

  String get fingerprint =>
      sha256.convert(CryptoUtils.getBytesFromPEMString(certificate)).toString();

  SecurityContext get context => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificate))
    ..usePrivateKeyBytes(utf8.encode(privateKey));

  static Future<TransferIdentity> generate() => Isolate.run(() {
        final pair = CryptoUtils.generateRSAKeyPair();
        final key = pair.privateKey as RSAPrivateKey;
        final csr = X509Utils.generateRsaCsrPem(
          {'CN': 'MySend'},
          key,
          pair.publicKey as RSAPublicKey,
        );
        final cert = X509Utils.generateSelfSignedCertificate(
          key, csr, 365 * 25,
          // 设备时钟偏差不应阻止首次使用。
          notBefore: DateTime.utc(2020),
        );
        return TransferIdentity(
            cert, CryptoUtils.encodeRSAPrivateKeyToPem(key));
      });

  static Future<TransferIdentity> loadOrCreate(File file) async {
    if (await file.exists()) {
      // 已存在但损坏时明确失败，避免悄悄更换已被其他设备信任的身份。
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final identity = TransferIdentity(
          json['certificate'] as String, json['privateKey'] as String);
      identity.context;
      return identity;
    }
    final identity = await generate();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
        jsonEncode({
          'certificate': identity.certificate,
          'privateKey': identity.privateKey,
        }),
        flush: true);
    await temp.rename(file.path);
    return identity;
  }
}
