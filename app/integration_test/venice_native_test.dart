import 'package:haptics_lab/app_access.dart';
// Offline only: verifies native credential decryption and visible readiness.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:haptics_lab/venice_chat_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows Venice key decrypts without sending a request', (
    tester,
  ) async {
    try {
      await VeniceLocalKey.load();
    } catch (error) {
      fail('Credential load: ${error.runtimeType}: $error');
    }
    await tester.pumpWidget(
      const MaterialApp(home: VeniceChatPage(role: AppRole.administrator)),
    );
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('本机密钥已加载').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('本机密钥已加载'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('venice_funded')))
          .value,
      false,
    );
    expect(find.textContaining('VENICE_INFERENCE_KEY_'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
