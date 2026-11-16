import 'dart:convert';
import 'package:crypto/crypto.dart';

/// LocalSend comparison: encode the first 128 digest bits in its 260-symbol alphabet.
/// Symbol order is shared with the plugin in assets/security/symbols.tsv.
class PairingVerification {
  static const alphabetSize = 260;
  final String combined;
  final List<int> indices;
  PairingVerification._(this.combined, this.indices);
  factory PairingVerification(String local, String remote) {
    final valid = RegExp(r'^[a-fA-F0-9]{64}$');
    if (!valid.hasMatch(local) || !valid.hasMatch(remote)) {
      throw const FormatException('设备证书指纹无效');
    }
    final fingerprints = [local.toUpperCase(), remote.toUpperCase()]..sort();
    final combined = fingerprints.join();
    final digest = sha256.convert(utf8.encode(combined)).bytes.take(16);
    var value = BigInt.zero;
    for (final byte in digest) {
      value = (value << 8) | BigInt.from(byte);
    }
    final base = BigInt.from(alphabetSize);
    final indices = List<int>.filled(16, 0);
    for (var i = indices.length - 1; i >= 0; i--) {
      indices[i] = (value % base).toInt();
      value ~/= base;
    }
    return PairingVerification._(combined, List.unmodifiable(indices));
  }
}
