import 'package:haptics_lab/app_access.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/speech_audio_player.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_tts.dart';
import 'package:haptics_lab/venice_wave_session.dart';

class Provider extends ModelProvider {
  Provider(this.answer);
  final Future<String> Function(String, ChatContext) answer;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) async => ModelReply(await answer(text, context), {});
}

class Tts extends VeniceTtsClient {
  Tts() : super(apiKey: 'fixture');
  final inputs = <String>[];
  @override
  Future<Uint8List> synthesize(
    String text, {
    String voice = 'eve',
    double speed = 1,
  }) async {
    inputs.add(text);
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  void cancel() {}
}

class Player implements SpeechAudioPlayer {
  final controller = StreamController<SpeechPlaybackEvent>.broadcast(
    sync: true,
  );
  @override
  Stream<SpeechPlaybackEvent> get events => controller.stream;
  @override
  Future<void> play(Uint8List bytes) async {
    controller.add(const SpeechPlaybackEvent(SpeechPlaybackState.playing));
    scheduleMicrotask(
      () => controller.add(
        const SpeechPlaybackEvent(SpeechPlaybackState.completed),
      ),
    );
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() => controller.close();
}

void main() {
  for (final deviates in [false, true]) {
    testWidgets(
      'confirmation executes only the concrete proposed target: deviates=$deviates',
      (tester) async {
        final session = VeniceWaveSession();
        var calls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: VeniceChatPage(
              role: AppRole.administrator,
              enableDialogueGuidance: false,
              loadKey: () async => 'fixture',
              waveSession: session,
              plannerFactory: (_, _) => Provider((text, _) async {
                calls++;
                if (calls == 1) return '{"action":"hold"}';
                final payload = jsonDecode(text);
                expect(payload['conversation']['pending_confirmation']['a'], 3);
                return jsonEncode({
                  'action': 'set',
                  'a': deviates ? 4 : 3,
                  'b': 0,
                  'waveform_id': session.selected,
                });
              }),
              chatFactory: (_, _) =>
                  Provider((_, _) async => calls == 1 ? 'A调到3好吗？' : '收到。'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(VeniceChatPage));
        state.funded = true;
        session.grant();
        state.input.text = '先保持当前设置';
        expect(await state.send(), true);
        state.input.text = '可以';
        expect(await state.send(), true);
        expect(calls, 2);
        expect(session.strength, [deviates ? 0 : 3, 0]);
        state.input.text = '可以';
        expect(await state.send(), true);
        expect(calls, 2); // Confirmation cannot repeat the action.
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }
  testWidgets(
    'real page shares context, guards speech, and chat retry never reapplies control',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = VeniceWaveSession();
      final tts = Tts();
      final plans = <Map<String, dynamic>>[];
      final receipts = <Map<String, dynamic>>[];
      var failChat = false;
      final planner = Provider((text, _) async {
        plans.add(jsonDecode(text) as Map<String, dynamic>);
        if (plans.length == 1) return '{"action":"hold"}';
        return jsonEncode({
          'action': 'set',
          'a': 3,
          'b': 1,
          'waveform_id': session.selected,
        });
      });
      final chat = Provider((_, context) async {
        receipts.add(
          jsonDecode(context.executionReceipt) as Map<String, dynamic>,
        );
        if (failChat) throw StateError('fixture');
        return '已经调高了。';
      });
      await tester.pumpWidget(
        MaterialApp(
          home: VeniceChatPage(
            role: AppRole.administrator,
            enableDialogueGuidance: false,
            loadKey: () async => 'fixture',
            waveSession: session,
            plannerFactory: (_, _) => planner,
            chatFactory: (_, _) => chat,
            ttsFactory: (_) => tts,
            speechPlayer: Player(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(VeniceChatPage));
      state.funded = true;
      session.grant();
      Future<bool> send(String text, {bool retry = false}) async {
        state.input.text = text;
        final result = await state.send(retry: retry) as bool;
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        return result;
      }

      expect(await send('请保持当前设置'), true);
      expect(tts.inputs.join(), isNot(contains('已经调高')));
      expect(tts.inputs.join(), contains('保持当前'));
      expect(receipts.last['execution']['status'], 'held');
      expect(await send('嗯'), true);
      expect(plans.length, 1);
      expect(await send('可以'), true); // No concrete proposal to confirm.
      expect(plans.length, 1);
      failChat = true;
      expect(await send('A调到3，B调到1'), false);
      expect(session.strength, [3, 1]);
      expect(plans.last['conversation']['recent_turns'], isNotEmpty);
      failChat = false;
      final count = plans.length;
      expect(await send('', retry: true), true);
      expect(plans.length, count);
      expect(receipts.last['chat_retry_only'], true);
      expect(session.strength, [3, 1]);
      expect(tts.inputs.join(), contains('没有再次调整'));
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('late planning cannot cross a stop and new grant', (
    tester,
  ) async {
    final session = VeniceWaveSession();
    final result = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: VeniceChatPage(
          role: AppRole.administrator,
          enableDialogueGuidance: false,
          loadKey: () async => 'fixture',
          waveSession: session,
          plannerFactory: (_, _) => Provider((_, _) => result.future),
          chatFactory: (_, _) => Provider((_, _) async => '已经调高了。'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(VeniceChatPage));
    state.funded = true;
    session.grant();
    state.input.text = 'A调到3';
    final work = state.send() as Future<bool>;
    await tester.pump();
    session.stop();
    session.grant();
    result.complete(
      jsonEncode({
        'action': 'set',
        'a': 3,
        'b': 0,
        'waveform_id': session.selected,
      }),
    );
    await work;
    expect(session.strength, [0, 0]);
    expect(state.pendingExecution.status, 'rejected');
    expect((state.turns.last as ChatTurn).text, isNot(contains('已经调高')));
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}
