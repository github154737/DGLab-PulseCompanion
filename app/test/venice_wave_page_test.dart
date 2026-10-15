import 'package:haptics_lab/app_access.dart';

import 'warm_test_helpers.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_wave_session.dart';
import 'package:haptics_lab/venice_control_provider.dart';
import 'package:haptics_lab/venice_transcription.dart';

class _Provider extends ModelProvider {
  _Provider(this.reply);
  final Future<ModelReply> Function(ChatContext) reply;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) => reply(context);
}

void main() {
  testWidgets(
    'vocalizations never call planner, explicit adjustment and stop still work',
    (tester) async {
      final session = VeniceWaveSession();
      var calls = 0;
      final receipts = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: VeniceChatPage(
            role: AppRole.administrator,
            enableDialogueGuidance: false,
            waveSession: session,
            loadKey: () async => 'fixture',
            plannerFactory: (_, requestedModel) {
              expect(requestedModel, veniceControlModel);
              return _Provider((_) async {
                calls++;
                return ModelReply(
                  jsonEncode({
                    'action': 'set',
                    'a': 4,
                    'b': 4,
                    'waveform_id': session.selected,
                  }),
                  {},
                );
              });
            },
            chatFactory: (_, requestedModel) {
              expect(requestedModel, veniceTextModel);
              return _Provider((context) async {
                receipts.add(context.executionReceipt);
                return const ModelReply('收到。', {});
              });
            },
          ),
        ),
      );
      await settleWarm(tester);
      await tapWarm(tester, 'venice_funded');
      await tapWarm(tester, 'nav_chat');
      session.grant();
      session.apply({
        'action': 'set',
        'a': 2,
        'b': 2,
        'waveform_id': session.selected,
      }, session.epoch);
      for (final text in ['嗯', '啊啊', '哼', 'Yeah.', 'OK']) {
        await tester.enterText(find.byKey(const Key('venice_message')), text);
        await tapWarm(tester, 'venice_send');
        expect(calls, 0);
        expect(session.strength, [2, 2]);
        expect(session.active, true);
        expect(receipts.last, contains('未调用控制接口'));
      }
      await tester.enterText(find.byKey(const Key('venice_message')), '嗯，调到四');
      await tapWarm(tester, 'venice_send');
      expect(calls, 1);
      expect(session.strength, [4, 4]);
      await tester.enterText(find.byKey(const Key('venice_message')), '停');
      await tapWarm(tester, 'venice_send');
      expect(calls, 1);
      expect(session.strength, [0, 0]);
      expect(session.active, false);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  for (final failure in ['prose', 'invalid_command', 'timeout', 'http']) {
    testWidgets(
      'ordinary chat survives planner $failure then later control works',
      (tester) async {
        final session = VeniceWaveSession();
        var calls = 0;
        final receipts = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: VeniceChatPage(
              role: AppRole.administrator,
              enableDialogueGuidance: false,
              waveSession: session,
              loadKey: () async => 'fixture',
              plannerFactory: (_, _) => _Provider((_) async {
                calls++;
                if (calls == 1) {
                  if (failure == 'timeout') {
                    throw TimeoutException('private payload');
                  }
                  if (failure == 'http') {
                    throw const ModelServiceException(
                      'private payload',
                      code: 'http_429',
                    );
                  }
                  return ModelReply(
                    failure == 'prose' ? '你好，今天过得怎么样？' : '{"action":"unknown"}',
                    {},
                  );
                }
                return ModelReply(
                  jsonEncode({
                    'action': 'set',
                    'a': 4,
                    'b': 2,
                    'waveform_id': session.selected,
                  }),
                  {},
                );
              }),
              chatFactory: (_, _) => _Provider((context) async {
                receipts.add(context.executionReceipt);
                return const ModelReply('收到。', {});
              }),
            ),
          ),
        );
        await settleWarm(tester);
        await tapWarm(tester, 'venice_funded');
        await tapWarm(tester, 'nav_chat');
        session.grant();
        session.apply({
          'action': 'set',
          'a': 2,
          'b': 2,
          'waveform_id': session.selected,
        }, session.epoch);
        await tester.enterText(
          find.byKey(const Key('venice_message')),
          '今天过得怎么样？',
        );
        await tapWarm(tester, 'venice_send');
        expect(session.active, true);
        expect(session.strength, [2, 2]);
        expect(receipts.single, contains('模拟保持'));
        expect(receipts.single, isNot(contains('private payload')));
        expect(find.textContaining('执行回执：'), findsWidgets);
        await tester.enterText(
          find.byKey(const Key('venice_message')),
          'A 强一点',
        );
        await tapWarm(tester, 'venice_send');
        expect(session.active, true);
        expect(session.strength, [4, 2]);
        expect(receipts.last, contains('A=4'));
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }
  for (final target in [2, 20]) {
    testWidgets(
      'control receipt is visible and chat retry does not replay target $target',
      (tester) async {
        final session = VeniceWaveSession();
        var planCalls = 0, chatCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: VeniceChatPage(
              role: AppRole.administrator,
              enableDialogueGuidance: false,
              waveSession: session,
              loadKey: () async => 'fixture',
              plannerFactory: (_, _) => _Provider((_) async {
                planCalls++;
                return ModelReply(
                  jsonEncode({
                    'action': 'set',
                    'a': target,
                    'b': 0,
                    'waveform_id': session.selected,
                  }),
                  {},
                );
              }),
              chatFactory: (_, _) => _Provider((_) async {
                chatCalls++;
                if (chatCalls == 1) {
                  throw StateError('fixture response failure');
                }
                return const ModelReply('收到。', {});
              }),
            ),
          ),
        );
        await settleWarm(tester);
        await tapWarm(tester, 'venice_funded');
        await tapWarm(tester, 'nav_chat');
        session.grant();
        await tester.enterText(
          find.byKey(const Key('venice_message')),
          'A 调到 $target',
        );
        await tapWarm(tester, 'venice_send');
        expect(planCalls, 1);
        expect(session.strength[0], target == 2 ? 2 : 0);
        expect(
          find.byKey(const Key('pending_control_receipt')),
          findsOneWidget,
        );
        if (target == 20) expect(find.textContaining('超出上限'), findsWidgets);
        await tapWarm(tester, 'retry_message');
        expect(planCalls, 1);
        expect(chatCalls, 2);
        expect(session.strength[0], target == 2 ? 2 : 0);
        expect(find.textContaining('重试仅补发聊天'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }
  testWidgets(
    'planner execution receipt reaches chat; stop rejects a late plan',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = VeniceWaveSession();
      final delayed = Completer<ModelReply>();
      var calls = 0;
      final receipts = <String>[];
      final plan = jsonEncode({
        'action': 'set',
        'a': 2,
        'b': 0,
        'waveform_id': session.selected,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: VeniceChatPage(
            role: AppRole.administrator,
            enableDialogueGuidance: false,
            waveSession: session,
            loadKey: () async => 'fixture',
            plannerFactory: (_, _) => _Provider((_) {
              calls++;
              return calls == 1
                  ? Future.value(ModelReply(plan, {}))
                  : delayed.future;
            }),
            chatFactory: (_, _) => _Provider((context) {
              receipts.add(context.executionReceipt);
              return Future.value(const ModelReply('收到。', {}));
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapWarm(tester, 'venice_funded');
      await tapWarm(tester, 'nav_chat');
      await tester.pumpAndSettle();
      session.grant();
      final input = find.byKey(const Key('venice_message'));
      final send = find.byKey(const Key('venice_send'));
      await tester.ensureVisible(input);
      await tester.enterText(input, 'A 通道强一点');
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pump(const Duration(milliseconds: 100));
      expect(session.strength, [2, 0]);
      expect(receipts.single, contains('A=2'));
      await tester.enterText(input, '换个波形');
      await tester.tap(send);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('venice_emergency_stop')));
      await tester.pump();
      delayed.complete(ModelReply(plan, {}));
      await tester.pump(const Duration(milliseconds: 100));
      expect(session.active, false);
      expect(session.strength, [0, 0]);
      expect(receipts.length, 1);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
