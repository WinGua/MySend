import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../../services/transfer/pairing_verification.dart';

class PairingVerificationView extends StatefulWidget {
  final PairingVerification verification;
  const PairingVerificationView({super.key, required this.verification});

  @override
  State<PairingVerificationView> createState() =>
      _PairingVerificationViewState();
}

class _PairingVerificationViewState extends State<PairingVerificationView> {
  static final _symbols = rootBundle
      .loadString('assets/security/symbols.tsv')
      .then((text) => text.trim().split('\n').map((row) {
            final columns = row.split('\t');
            return (columns[0], int.parse(columns[1], radix: 16));
          }).toList());
  bool _text = false;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('请在另一台设备打开“核对图标”，按从左到右、从上到下的顺序核对。'),
          const SizedBox(height: 12),
          Directionality(
            textDirection: TextDirection.ltr,
            child: _text
                ? SelectableText(widget.verification.combined)
                : FutureBuilder<List<(String, int)>>(
                    future: _symbols,
                    builder: (context, snapshot) {
                      final symbols = snapshot.data;
                      if (snapshot.hasError) {
                        return const Text('图标加载失败，请切换为文字核对。');
                      }
                      if (symbols == null) return const ProgressRing();
                      return SizedBox(
                        width: 224,
                        child: GridView.count(
                          crossAxisCount: 4,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            for (final index in widget.verification.indices)
                              Center(
                                child: Text(
                                    String.fromCharCode(symbols[index].$2),
                                    semanticsLabel:
                                        symbols[index].$1.replaceAll('_', ' '),
                                    style: const TextStyle(
                                        fontFamily: 'MySendPairingSymbols',
                                        fontSize: 32)),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          Button(
            onPressed: () => setState(() => _text = !_text),
            child: Text(_text ? '显示图标' : '显示证书指纹'),
          ),
        ],
      );
}
