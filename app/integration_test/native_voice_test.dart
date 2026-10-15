import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/voice_page.dart';
import 'package:haptics_lab/voice_client.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aihaptics/pcm');
  testWidgets(
    'platform vault and silent PCM streaming stop work on the native runner',
    (tester) async {
      final fixture = Uint8List.fromList(
        utf8.encode('fixture-session-token-never-a-real-key'),
      );
      final sealed = await channel.invokeMethod<Uint8List>('seal', fixture);
      expect(sealed, isNotNull);
      expect(sealed, isNot(orderedEquals(fixture)));
      final clear = await channel.invokeMethod<Uint8List>('unseal', sealed);
      expect(clear, orderedEquals(fixture));
      final damaged = Uint8List.fromList(sealed!);
      damaged[damaged.length - 1] ^= 1;
      await expectLater(
        channel.invokeMethod<Uint8List>('unseal', damaged),
        throwsA(isA<PlatformException>()),
      );
      await channel.invokeMethod<void>('setup');
      await channel.invokeMethod<void>('feed', Uint8List(4800));
      final pending = await channel.invokeMethod<int>('pending');
      expect(pending, greaterThanOrEqualTo(0));
      final watch = Stopwatch()..start();
      await channel.invokeMethod<void>('stop');
      expect(await channel.invokeMethod<int>('pending'), 0);
      // This measures local dispatch/queue flushing, not acoustic silence.
      debugPrint('PCM local flush ms: ${watch.elapsedMilliseconds}');
      CoreBridge().call({'op': 'reset_simulation'});
      await tester.pumpWidget(
        MaterialApp(
          home: VoicePage(
            client: VoiceClient(CoreBridge().call),
            serviceAddress: 'http://127.0.0.1:8790',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('实时语音内测 · 模拟模式'), findsOneWidget);
      expect(find.text('立即停止并撤销模拟权限'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
