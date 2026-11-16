import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/services/transfer/pairing_verification.dart';
import 'package:mysend/ui/widgets/glass.dart';
import 'package:mysend/ui/widgets/pairing_verification_view.dart';

void main() {
  testWidgets('窄屏大字体下可滚动核对 16 个图标并切换为指纹', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final verification = PairingVerification('00' * 32, 'ff' * 32);
    await tester.pumpWidget(FluentApp(
      home: MediaQuery(
        data: const MediaQueryData(
            size: Size(320, 568), textScaler: TextScaler.linear(2)),
        child: Center(
            child: SingleChildScrollView(
                child: GlassDialog(
          title: '核对密钥',
          content: PairingVerificationView(verification: verification),
          actions: [Button(onPressed: () {}, child: const Text('关闭'))],
        ))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(GridView), findsOneWidget);
    final symbols = tester
        .widgetList<Text>(find.byType(Text))
        .where((text) => text.style?.fontFamily == 'MySendPairingSymbols');
    expect(symbols.length, 16);
    await tester.ensureVisible(find.text('显示证书指纹'));
    await tester.tap(find.text('显示证书指纹'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text(verification.combined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
