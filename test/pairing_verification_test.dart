import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/services/transfer/pairing_verification.dart';

void main() {
  test('与 LocalSend 的 260 进制图标编码一致且与端点顺序无关', () {
    final a = '00' * 32;
    final b = 'ff' * 32;
    final expected = [
      52,
      240,
      92,
      21,
      220,
      8,
      7,
      243,
      9,
      169,
      193,
      203,
      67,
      21,
      8,
      164
    ];
    expect(PairingVerification(a, b).indices, expected);
    expect(PairingVerification(b.toUpperCase(), a).indices, expected);
    expect(PairingVerification(a, 'fe' * 32).indices, isNot(expected));
    expect(
        PairingVerification(a, b).combined, a.toUpperCase() + b.toUpperCase());
    expect(() => PairingVerification(a, 'invalid'), throwsFormatException);
  });

  test('两端使用同一份图标顺序和字体', () async {
    final here = Directory('assets/security');
    final plugin = Directory('../SPW-Send/plugin/src/main/resources/pairing');
    final rows = await File('${here.path}/symbols.tsv').readAsLines();
    expect(rows.length, PairingVerification.alphabetSize);
    expect(rows.toSet().length, rows.length);
    // The plugin checkout is optional in standalone CI.
    if (await plugin.exists()) {
      for (final name in [
        'symbols.tsv',
        'pairing-symbols.otf',
        'NOTICE.txt',
        'LICENSE-APACHE'
      ]) {
        expect(await File('${here.path}/$name').readAsBytes(),
            await File('${plugin.path}/$name').readAsBytes(),
            reason: name);
      }
    }
  });
}
