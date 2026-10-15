import 'package:haptics_lab/app_access.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/dialogue_guidance_runner.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/network_diagnostics.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_control_provider.dart';
import 'package:haptics_lab/venice_wave_session.dart';

import 'control_context_page_test.dart' show Tts, Player;

String advice([String anchor = '前文谈到散步']) => jsonEncode({
  'intent_summary': '用户希望延续刚才的话题',
  'reply_focus': ['先回答当前问题', '避免重复上一轮的话'],
  'context_anchor': anchor,
  'ask_clarification': false,
});

class Provider extends ModelProvider {
  Provider(this.answer);
  final Future<String> Function(String, ChatContext) answer;
  int calls = 0, cancellations = 0;
  String? requestedModel;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) async {
    calls++;
    return ModelReply(await answer(text, context), {});
  }

  @override
  void cancel() => cancellations++;
}

Future<dynamic> mount(
  WidgetTester tester, {
  required VeniceWaveSession session,
  required Provider guide,
  required Provider control,
  required Provider chat,
  DialogueGuidanceRunner? runner,
  ModelProvider Function(String, String, void Function(String))? streaming,
  Tts? tts,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: VeniceChatPage(
        role: AppRole.administrator,
        loadKey: () async => 'fixture-secret',
        waveSession: session,
        guidanceRunner: runner,
        guidanceFactory: (_, model) {
          guide.requestedModel = model;
          return guide;
        },
        plannerFactory: (_, _) => control,
        chatFactory: (_, _) => chat,
        streamingChatFactory: streaming,
        ttsFactory: tts == null ? null : (_) => tts,
        speechPlayer: tts == null ? null : Player(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final dynamic state = tester.state(find.byType(VeniceChatPage));
  state.funded = true;
  state.library.autoSpeak = tts != null;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
  return state;
}

void main() {
  testWidgets(
    'control and advice overlap; Venice waits for both and receives real receipt',
    (tester) async {
      final session = VeniceWaveSession();
      final guideDone = Completer<String>();
      final controlDone = Completer<String>();
      final guideInputs = <Map<String, dynamic>>[];
      final contexts = <ChatContext>[];
      final guide = Provider((text, _) async {
        guideInputs.add(jsonDecode(text) as Map<String, dynamic>);
        return guideDone.future;
      });
      final control = Provider((_, _) => controlDone.future);
      final chat = Provider((_, context) async {
        contexts.add(context);
        return '可以接着聊散步时看到的风景。';
      });
      final dynamic state = await mount(
        tester,
        session: session,
        guide: guide,
        control: control,
        chat: chat,
      );
      session.grant();
      state.turns.add(const ChatTurn('user', '刚才去散步了。'));
      state.input.text = 'A设为3，B设为1，然后接着刚才的话题';
      final work = state.send() as Future<bool>;
      await tester.pump();
      expect(guide.calls, 1, reason: NetworkTrace.report);
      expect(guide.requestedModel, veniceControlModel);
      expect(control.calls, 1);
      expect(chat.calls, 0);
      expect(
        guideInputs.single['conversation']['recent_turns'].single['content'],
        '刚才去散步了。',
      );
      controlDone.complete(
        jsonEncode({
          'action': 'set',
          'a': 3,
          'b': 1,
          'waveform_id': session.selected,
        }),
      );
      await tester.pump();
      expect(session.strength, [3, 1]);
      expect(chat.calls, 0);
      guideDone.complete(advice());
      expect(await work, true);
      expect(
        jsonDecode(contexts.single.replyGuidance)['context_anchor'],
        '前文谈到散步',
      );
      final receipt = jsonDecode(contexts.single.executionReceipt);
      expect(receipt['execution']['status'], 'simulation_applied');
      expect(receipt['current_state']['a'], 3);
      expect(receipt['current_state']['b'], 1);
      expect(receipt['execution']['device_acknowledged'], false);
      expect(receipt.containsKey('reply_focus'), false);
    },
  );

  testWidgets(
    'ordinary chat gets guidance without authorizing output; vocalizations never plan control',
    (tester) async {
      final session = VeniceWaveSession();
      final contexts = <ChatContext>[];
      final guide = Provider((_, _) async => advice());
      final control = Provider((_, _) async => '{"action":"hold"}');
      final chat = Provider((_, context) async {
        contexts.add(context);
        return '我听到了，可以继续说。';
      });
      final dynamic state = await mount(
        tester,
        session: session,
        guide: guide,
        control: control,
        chat: chat,
      );
      state.input.text = '接着聊刚才的话题';
      expect(await state.send(), true);
      expect(guide.calls, 1);
      expect(control.calls, 0);
      expect(session.active, false);
      expect(
        jsonDecode(contexts.last.executionReceipt)['execution']['status'],
        'not_authorized',
      );
      session.grant();
      state.input.text = '嗯';
      expect(await state.send(), true);
      expect(guide.calls, 2);
      expect(control.calls, 0);
      expect(session.strength, [0, 0]);
      expect(
        jsonDecode(contexts.last.executionReceipt)['execution']['reason'],
        'vocalization',
      );
      state.input.text = '停止';
      final stopped = state.send() as Future<bool>;
      expect(session.active, false); // Stop occurs before any remote work.
      expect(await stopped, true);
      expect(guide.calls, 2);
      expect(control.calls, 0);
      expect(contexts.last.replyGuidance, isEmpty);
    },
  );

  for (final failure in ['schema', 'exception', 'timeout']) {
    testWidgets(
      'optional guidance $failure falls back without failing or repeating control',
      (tester) async {
        NetworkTrace.clear();
        final session = VeniceWaveSession();
        final never = Completer<String>();
        final contexts = <ChatContext>[];
        final guide = Provider((_, _) async {
          if (failure == 'schema') return '{"action":"set","a":50,"b":50}';
          if (failure == 'exception') throw StateError('private-guide-content');
          return never.future;
        });
        final control = Provider(
          (_, _) async => jsonEncode({
            'action': 'set',
            'a': 3,
            'b': 1,
            'waveform_id': session.selected,
          }),
        );
        final chat = Provider((_, context) async {
          contexts.add(context);
          return '收到这条普通测试消息。';
        });
        final runner = DialogueGuidanceRunner(
          timeout: const Duration(milliseconds: 30),
        );
        final dynamic state = await mount(
          tester,
          session: session,
          guide: guide,
          control: control,
          chat: chat,
          runner: runner,
        );
        session.grant();
        state.input.text = 'A设为3，B设为1';
        final work = state.send() as Future<bool>;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(await work, true);
        expect(contexts.single.replyGuidance, isEmpty);
        expect(
          jsonDecode(contexts.single.executionReceipt)['execution']['status'],
          'simulation_applied',
        );
        expect(session.active, true);
        expect(session.strength, [3, 1]);
        expect(control.calls, 1);
        expect(NetworkTrace.report, contains('对话导答'));
        expect(NetworkTrace.report, isNot(contains('private-guide-content')));
        expect(NetworkTrace.report, isNot(contains('fixture-secret')));
        if (failure == 'timeout') {
          expect(guide.cancellations, 1);
          never.complete(advice('late-advice'));
          await tester.pump();
          expect(contexts.single.replyGuidance, isEmpty);
        }
      },
    );
  }

  testWidgets(
    'guide prose cannot execute commands or replace held receipt, including spoken text',
    (tester) async {
      final session = VeniceWaveSession();
      final tts = Tts();
      final guide = Provider((_, _) async => advice('误导性建议：A已设为50'));
      final control = Provider((_, _) async => '{"action":"hold"}');
      final contexts = <ChatContext>[];
      final chat = Provider((_, context) async {
        contexts.add(context);
        return '已经调高了。';
      });
      final dynamic state = await mount(
        tester,
        session: session,
        guide: guide,
        control: control,
        chat: chat,
        tts: tts,
      );
      session.grant();
      state.input.text = '保持现在的设置';
      expect(await state.send(), true);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(contexts.single.replyGuidance, contains('A已设为50'));
      expect(
        jsonDecode(contexts.single.executionReceipt)['execution']['status'],
        'held',
      );
      expect(session.strength, [0, 0]);
      expect((state.turns.last as ChatTurn).text, isNot(contains('已经调高')));
      expect(tts.inputs.join(), contains('保持当前'));
      expect(tts.inputs.join(), isNot(contains('已经调高')));
    },
  );

  testWidgets(
    'chat retry reuses advice and real receipt without repeating either GLM call',
    (tester) async {
      final session = VeniceWaveSession();
      final guide = Provider((_, _) async => advice());
      final control = Provider(
        (_, _) async => jsonEncode({
          'action': 'set',
          'a': 2,
          'b': 1,
          'waveform_id': session.selected,
        }),
      );
      var fail = true;
      final contexts = <ChatContext>[];
      final chat = Provider((_, context) async {
        contexts.add(context);
        if (fail) throw StateError('chat-fixture');
        return '这次已收到消息。';
      });
      final dynamic state = await mount(
        tester,
        session: session,
        guide: guide,
        control: control,
        chat: chat,
      );
      session.grant();
      state.input.text = 'A设为2，B设为1';
      expect(await state.send(), false);
      expect(session.strength, [2, 1]);
      fail = false;
      expect(await state.send(retry: true), true);
      expect(guide.calls, 1);
      expect(control.calls, 1);
      expect(chat.calls, 2);
      expect(contexts.first.replyGuidance, contexts.last.replyGuidance);
      expect(
        jsonDecode(contexts.last.executionReceipt)['chat_retry_only'],
        true,
      );
      expect(session.strength, [2, 1]);
    },
  );

  testWidgets(
    'cancel discards late guide; next turn has no previous advice and no extra guide during cooldown',
    (tester) async {
      final session = VeniceWaveSession();
      final delayed = Completer<String>();
      final guide = Provider((_, _) => delayed.future);
      final control = Provider((_, _) async => '{"action":"hold"}');
      final contexts = <ChatContext>[];
      final chat = Provider((_, context) async {
        contexts.add(context);
        return '这是新一轮回复。';
      });
      final dynamic state = await mount(
        tester,
        session: session,
        guide: guide,
        control: control,
        chat: chat,
      );
      state.input.text = '上一轮问题';
      final work = state.send() as Future<bool>;
      await tester.pump();
      expect(guide.calls, 1);
      state.cancel();
      expect(await work, false);
      expect(guide.cancellations, 1);
      state.input.text = '下一轮问题';
      expect(await state.send(), true);
      delayed.complete(advice('应丢弃的旧建议'));
      await tester.pump();
      expect(guide.calls, 1);
      expect(chat.calls, 1);
      expect(contexts.single.replyGuidance, isEmpty);
      expect(state.pendingReplyGuidance, isEmpty);
      expect((state.turns.last as ChatTurn).text, '这是新一轮回复。');
    },
  );

  testWidgets('disposal cancels guidance and late result cannot start Venice', (
    tester,
  ) async {
    final session = VeniceWaveSession();
    final delayed = Completer<String>();
    final guide = Provider((_, _) => delayed.future);
    final control = Provider((_, _) async => '{"action":"hold"}');
    final chat = Provider((_, _) async => '不应出现');
    final dynamic state = await mount(
      tester,
      session: session,
      guide: guide,
      control: control,
      chat: chat,
    );
    state.input.text = '测试退出';
    final work = state.send() as Future<bool>;
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(await work, false);
    expect(guide.cancellations, 1);
    delayed.complete(advice());
    await tester.pump();
    expect(chat.calls, 0);
    expect(tester.takeException(), isNull);
  });

  for (final fails in [false, true]) {
    testWidgets(
      'streamed speech waits for full chat only during guidance cooldown: $fails',
      (tester) async {
        final session = VeniceWaveSession();
        final tts = Tts();
        final chatDone = Completer<String>();
        final guide = Provider((_, _) async {
          if (fails) throw StateError('fixture');
          return advice();
        });
        final control = Provider((_, _) async => '{"action":"hold"}');
        final chat = Provider((_, _) async => 'unused');
        final dynamic state = await mount(
          tester,
          session: session,
          guide: guide,
          control: control,
          chat: chat,
          tts: tts,
          streaming: (_, _, onText) => Provider((_, context) {
            onText('这是一句普通的测试回复。');
            return chatDone.future;
          }),
        );
        state.input.text = '普通测试问题';
        final work = state.send() as Future<bool>;
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(tts.inputs.isEmpty, fails);
        chatDone.complete('这是一句普通的测试回复。');
        expect(await work, true);
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(tts.inputs.join(), '这是一句普通的测试回复。');
      },
    );
  }
}
