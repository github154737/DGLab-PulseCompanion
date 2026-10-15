import 'package:haptics_lab/app_access.dart';

import 'warm_test_helpers.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_wave_session.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/chat_context.dart';

class _Chat extends ModelProvider {
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) async => const ModelReply('测试回复', {});
}

void main() {
  testWidgets(
    'phone layout sends text and background retains authorized waveform output',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final waves = VeniceWaveSession();
      await tester.pumpWidget(
        MaterialApp(
          home: VeniceChatPage(
            role: AppRole.administrator,
            enableDialogueGuidance: false,
            loadKey: () async => 'fixture',
            waveSession: waves,
            chatFactory: (_, _) => _Chat(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapWarm(tester, 'venice_funded');
      await tapWarm(tester, 'nav_chat');
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('venice_message'));
      await tester.scrollUntilVisible(
        input,
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(input, '测试文字发送');
      await tester.ensureVisible(find.byKey(const Key('venice_send')));
      await tester.tap(find.byKey(const Key('venice_send')));
      await tester.pumpAndSettle();
      expect(find.text('测试回复'), findsOneWidget);
      waves.grant();
      waves.apply({
        'action': 'set',
        'a': 2,
        'b': 0,
        'waveform_id': waves.selected,
      }, waves.epoch);
      expect(waves.strength, [2, 0]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(waves.strength, [2, 0]);
      expect(waves.active, true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(waves.active, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      waves.dispose();
    },
  );
}
