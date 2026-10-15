import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/control_conversation.dart';
import 'package:haptics_lab/control_reply_guard.dart';
import 'package:haptics_lab/venice_wave_session.dart';

void main() {
  late VeniceWaveSession session;
  setUp(() => session = VeniceWaveSession()..grant());
  tearDown(() => session.dispose());
  void set(int a, int b, {String? wave}) => session.apply({
    'action': 'set',
    'a': a,
    'b': b,
    'waveform_id': wave ?? session.selected,
  }, session.epoch);

  test('receipt captures actual before/after and rejects without losing last success', () {
    final memory = ControlConversation();
    final first = session.selected;
    set(2, 3, wave: session.waves[1].id);
    final receipt = session.lastExecution!;
    memory.record(receipt);
    expect(receipt.status, 'simulation_applied');
    expect(receipt.before['a'], 0);
    expect(receipt.after['a'], 2);
    expect(session.snapshot()['previous_waveform_id'], first);
    expect(receipt.toJson()['device_acknowledged'], false);
    set(50, 50);
    memory.record(session.lastExecution!);
    expect(memory.lastExecution!.status, 'rejected');
    expect(memory.lastExecution!.reason, 'limit_exceeded');
    expect(memory.lastApplied, same(receipt));
    expect(receipt.after['a'], 2);
    expect(session.strength, [2, 3]);
  });

  test('physical target and stop do not claim hardware acknowledgement', () {
    session.grant(toDevice: true);
    set(1, 1);
    expect(session.lastExecution!.status, 'target_updated');
    expect(session.lastExecution!.summary(session.snapshot()), contains('尚无'));
    session.apply({'action': 'stop'}, session.epoch);
    expect(session.lastExecution!.status, 'stop_requested');
    expect(session.lastExecution!.summary(session.snapshot()), contains('待确认'));
  });

  test('shared context bounds history and contains real waveform history', () {
    final memory = ControlConversation();
    final first = session.selected;
    set(1, 1, wave: session.waves[1].id);
    memory.record(session.lastExecution!);
    final history = List.generate(
      30,
      (i) => ChatTurn(i.isEven ? 'user' : 'assistant', '$i'),
    );
    final payload = jsonDecode(
      memory.plannerInput('换回刚才的', session.snapshot(), history),
    );
    expect(payload['user_message'], '换回刚才的');
    expect(payload['local_state']['previous_waveform_id'], first);
    expect(payload['conversation']['recent_turns'].length, 8);
    expect(payload['conversation']['recent_turns'].first['content'], '22');
    expect(payload['conversation']['last_applied_action']['after']['a'], 1);
    memory.clear();
    expect(memory.lastApplied, isNull);
  });

  test(
    'confirmation needs a concrete, bounded, fresh proposal in same state',
    () {
      var now = DateTime(2026);
      final memory = ControlConversation(now: () => now);
      session.apply({'action': 'hold'}, session.epoch);
      final held = session.lastExecution!;
      for (final text in ['要不要再调整一下？', 'A调到50好吗？', 'A调到3。']) {
        memory.rememberProposal(text, held, session.snapshot());
        expect(memory.proposal(session.snapshot()), isNull);
      }
      memory.rememberProposal('A调到3好吗？', held, session.snapshot());
      expect(memory.proposal(session.snapshot())?['a'], 3);
      expect(memory.proposal(session.snapshot())?['b'], 0);
      now = now.add(const Duration(minutes: 3));
      expect(memory.proposal(session.snapshot()), isNull);
      memory.rememberProposal('A调到3好吗？', held, session.snapshot());
      session.invalidate('manual_strength');
      expect(memory.proposal(session.snapshot()), isNull);
    },
  );

  test('no-op set is not remembered as a successful change', () {
    final memory = ControlConversation();
    set(0, 0);
    memory.record(session.lastExecution!);
    expect(memory.lastApplied, isNull);
  });

  test(
    'waveform confirmation resolves only one known name and preserves strength',
    () {
      final memory = ControlConversation();
      session.apply({'action': 'hold'}, session.epoch);
      memory.rememberProposal(
        '换成${session.waves[1].name}好吗？',
        session.lastExecution!,
        session.snapshot(),
      );
      final proposal = memory.proposal(session.snapshot());
      expect(proposal?['waveform_id'], session.waves[1].id);
      expect(proposal?['a'], 0);
      expect(proposal?['b'], 0);
      memory.rememberProposal(
        '换成不存在的波形好吗？',
        session.lastExecution!,
        session.snapshot(),
      );
      expect(memory.proposal(session.snapshot()), isNull);
    },
  );

  test('stream gate never leaks a split false completion to text or TTS', () {
    session.apply({'action': 'hold'}, session.epoch);
    final receipt = session.lastExecution!;
    var replacements = 0;
    final guard = ControlReplyGuard(
      fallback: () => receipt.summary(session.snapshot()),
      onReplacement: () => replacements++,
    );
    expect(guard.add('你好。已经'), '你好。');
    expect(guard.add('你好。已经调高'), '你好。');
    final output = guard.add('你好。已经调高了。今天怎么样？', complete: true);
    expect(output, isNot(contains('已经调高')));
    expect(output, contains('保持当前波形和强度'));
    expect(output, endsWith('今天怎么样？'));
    expect(replacements, 1);
  });

  test(
    'gate checks a complete sentence rather than releasing comma clauses',
    () {
      final guard = ControlReplyGuard(fallback: () => '本轮未调整。');
      expect(guard.add('A=20，'), isEmpty);
      expect(guard.add('A=20，已经调好了。', complete: true), '本轮未调整。');
      expect(ControlReplyGuard.claimsAction('没能调整，已经调高了。'), true);
      expect(ControlReplyGuard.claimsAction('已经换好了。'), true);
      expect(ControlReplyGuard.claimsAction('已经换了。'), true);
      expect(ControlReplyGuard.claimsAction('已经加了。'), true);
      expect(
        ControlReplyGuard.claimsAction('The intensity has increased.'),
        true,
      );
    },
  );

  test('ordinary chat, proposals and failure statements remain unchanged', () {
    for (final text in ['你好，今天怎么样？', 'A调到3好吗？', '这轮没有调高。', '要不要再提高一点？']) {
      final guard = ControlReplyGuard(fallback: () => '错误替换');
      expect(guard.add(text, complete: true), text);
    }
  });

  test(
    'reply checks latest state and retries never repeat a success claim',
    () {
      set(3, 1);
      final receipt = session.lastExecution!;
      expect(
        receipt.summary(session.snapshot(), retry: true),
        contains('没有再次调整'),
      );
      session.stop();
      final guard = ControlReplyGuard(
        fallback: () => receipt.summary(session.snapshot()),
      );
      final output = guard.add('已经调到3了。', complete: true);
      expect(output, contains('会话已停止'));
      expect(output, contains('A=0 / B=0'));
    },
  );
}
