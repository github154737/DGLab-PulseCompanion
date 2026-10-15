import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_chat_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aihaptics/pcm');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'key load uses the Windows vault without a Dart filesystem path',
    () async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            expect(call.arguments, isNull);
            return Uint8List.fromList(
              utf8.encode('VENICE_INFERENCE_KEY_fixture'),
            );
          });
      expect(await VeniceLocalKey.load(), 'VENICE_INFERENCE_KEY_fixture');
      expect(methods, ['load_venice_key']);
    },
  );
  test('native failure retains a safe diagnostic category', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'key_read_denied');
        });
    await expectLater(
      VeniceLocalKey.load(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'key_read_denied',
        ),
      ),
    );
  });
}
