import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/model_settings.dart';
import 'package:haptics_lab/api_model_provider.dart';

void main() {
  testWidgets(
    'API configuration masks the key and waits for explicit testing',
    (tester) async {
      final config = ModelConfiguration()..source = ModelSource.api;
      var tests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ModelSettings(
                configuration: config,
                busy: false,
                onChanged: () {},
                onTest: () => tests++,
                testStatus: '',
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('模型与对话设置'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('model_endpoint')),
        'https://example.com/v1',
      );
      await tester.enterText(find.byKey(const Key('model_name')), 'fixture');
      await tester.enterText(
        find.byKey(const Key('model_api_key')),
        'fixture-token',
      );
      expect(tests, 0);
      final provider = config.createProvider() as ApiModelProvider;
      expect(provider.timeout, const Duration(seconds: 30));
      expect(provider.maxTokens, 1200);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('model_api_key')))
            .obscureText,
        true,
      );
      expect(
        (config.createProvider() as ApiModelProvider).endpoint.toString(),
        'https://example.com/v1/chat/completions',
      );
      await tester.ensureVisible(find.byKey(const Key('test_model')));
      await tester.tap(find.byKey(const Key('test_model')));
      expect(tests, 1);
      await tester.pumpWidget(const SizedBox());
      config.dispose();
    },
  );
}
