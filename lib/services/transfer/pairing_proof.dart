import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'transfer_identity.dart';

/// One-use, short-lived pairing challenges. Public discovery fields are not credentials.
class PairingProof {
  final TransferIdentity identity;
  final String session;
  final DateTime Function() now;
  final Map<String, _Challenge> _pending = {};
  static const fields = [
    'id',
    'fingerprint',
    'role',
    'form',
    'name',
    'port',
    'session',
    'token'
  ];
  PairingProof(this.identity, this.session, {DateTime Function()? now})
      : now = now ?? DateTime.now;

  static String _random() =>
      base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256)));
  Map<String, dynamic> issue(String peerId, String fingerprint) {
    _pending.removeWhere((_, c) => !now().isBefore(c.expires));
    while (_pending.length >= 128) {
      _pending.remove(_pending.keys.first);
    }
    final id = _random();
    final nonce = _random();
    _pending[id] = _Challenge(
        peerId, fingerprint, nonce, now().add(const Duration(seconds: 30)));
    return {
      'ok': true,
      'challengeId': id,
      'challenge': nonce,
      'fingerprint': identity.fingerprint,
      'session': session
    };
  }

  static Uint8List payload(String serverFingerprint, String serverSession,
      String challengeId, String nonce, Map<String, dynamic> body) {
    final result = BytesBuilder()..add(utf8.encode('MySend-Pair-v1\n'));
    for (final value in [
      serverFingerprint,
      serverSession,
      challengeId,
      nonce,
      ...fields.map((key) => (body[key] ?? (key == 'port' ? 0 : '')).toString())
    ]) {
      final bytes = utf8.encode(value);
      result
        ..add(ascii.encode('${bytes.length}:'))
        ..add(bytes);
    }
    return result.takeBytes();
  }

  static void sign(Map<String, dynamic> body, Map<String, dynamic> challenge,
      TransferIdentity identity, String serverFingerprint) {
    if (challenge['fingerprint'] != serverFingerprint ||
        challenge['challengeId'] is! String ||
        challenge['challenge'] is! String ||
        challenge['session'] is! String) {
      throw const FormatException('配对挑战无效');
    }
    body['challengeId'] = challenge['challengeId'];
    body['certificate'] = identity.certificate;
    body['proof'] = base64.encode(CryptoUtils.rsaSign(
        CryptoUtils.rsaPrivateKeyFromPem(identity.privateKey),
        payload(serverFingerprint, challenge['session'],
            challenge['challengeId'], challenge['challenge'], body)));
  }

  bool verify(Map<String, dynamic> body) {
    final id = body['challengeId'];
    final challenge = id is String ? _pending.remove(id) : null;
    if (challenge == null ||
        !now().isBefore(challenge.expires) ||
        challenge.peerId != body['id'] ||
        challenge.fingerprint != body['fingerprint']) return false;
    try {
      final pem = body['certificate'] as String;
      if (pem.length > 16384 || (body['proof'] as String).length > 2048) {
        return false;
      }
      if (sha256.convert(CryptoUtils.getBytesFromPEMString(pem)).toString() !=
          challenge.fingerprint) return false;
      final cert = X509Utils.x509CertificateFromPem(pem);
      final validity = cert.tbsCertificate!.validity;
      if (now().isBefore(validity.notBefore) ||
          !now().isBefore(validity.notAfter) ||
          !X509Utils.checkX509Signature(pem)) return false;
      final hex = cert.tbsCertificate!.subjectPublicKeyInfo.bytes!;
      final key = CryptoUtils.rsaPublicKeyFromDERBytes(Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16)
      ]));
      if (key.modulus!.bitLength < 2048) return false;
      return CryptoUtils.rsaVerify(
          key,
          payload(identity.fingerprint, session, id as String, challenge.nonce,
              body),
          base64.decode(body['proof']));
    } catch (_) {
      return false;
    }
  }

  void clear() => _pending.clear();
}

class _Challenge {
  final String peerId, fingerprint, nonce;
  final DateTime expires;
  _Challenge(this.peerId, this.fingerprint, this.nonce, this.expires);
}
