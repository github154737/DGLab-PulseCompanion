// Operator integration check: requires the local service on port 8790.
// No upstream model, microphone or output-device action is requested.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:haptics_lab/voice_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('desktop restores local owner without invitation', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    await tester.pumpWidget(
      const MaterialApp(
        home: VoicePage(serviceAddress: 'http://127.0.0.1:8790'),
      ),
    );
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('本机测试 · 自动登录 · 不占内测名额').evaluate().isNotEmpty) break;
    }
    expect(find.text('本机测试 · 自动登录 · 不占内测名额'), findsOneWidget);
    expect(find.text('一次性邀请码 / 账号恢复码'), findsNothing);
    expect(find.text('兑换并登录'), findsNothing);
    final connect = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '连接 / 重新连接'),
    );
    expect(connect.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
