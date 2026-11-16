import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/services/transfer/pairing_proof.dart';
import 'package:mysend/services/transfer/transfer_identity.dart';

void main() {
  late TransferIdentity server, peer, attacker;
  setUpAll(() async {
    server = await TransferIdentity.generate();
    peer = await TransferIdentity.generate();
    attacker = await TransferIdentity.generate();
  });
  test('私钥证明一次有效，重放、篡改和换钥均无效', () {
    final proof = PairingProof(server, 'server-session');
    Map<String, dynamic> signed([TransferIdentity? signer]) {
      final challenge = proof.issue('peer', peer.fingerprint);
      final body = <String, dynamic>{
        'id': 'peer',
        'fingerprint': peer.fingerprint,
        'role': 'android',
        'name': '手机',
        'port': 1234,
        'token': 'offered-token'
      };
      PairingProof.sign(body, challenge, signer ?? peer, server.fingerprint);
      return body;
    }

    final valid = signed();
    expect(proof.verify(valid), isTrue);
    expect(proof.verify(valid), isFalse);
    final changed = signed()..['token'] = 'substituted-token';
    expect(proof.verify(changed), isFalse);
    expect(proof.verify(signed(attacker)), isFalse);
    final otherServer = PairingProof(attacker, 'other');
    expect(otherServer.verify(signed()), isFalse);
  });
  test('过期挑战和服务重启前的挑战均不能签发 token', () {
    var time = DateTime.now();
    final proof = PairingProof(server, 'session', now: () => time);
    final body = <String, dynamic>{
      'id': 'peer',
      'fingerprint': peer.fingerprint
    };
    PairingProof.sign(
        body, proof.issue('peer', peer.fingerprint), peer, server.fingerprint);
    time = time.add(const Duration(seconds: 31));
    expect(proof.verify(body), isFalse);
    PairingProof.sign(
        body, proof.issue('peer', peer.fingerprint), peer, server.fingerprint);
    proof.clear();
    expect(proof.verify(body), isFalse);
  });
}
