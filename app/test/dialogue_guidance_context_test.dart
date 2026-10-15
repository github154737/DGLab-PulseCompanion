import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/dialogue_guidance_context.dart';

Map<String, dynamic> input(String text, List<ChatTurn> history) =>
    jsonDecode(buildDialogueGuidanceInput(text, history))
        as Map<String, dynamic>;

List<dynamic> turns(Map<String, dynamic> data) =>
    data['conversation']['recent_turns'] as List<dynamic>;

void main() {
  test('retains older referents beyond four conversation rounds', () {
    final history = [
      const ChatTurn('user', '周末的计划是公园散步和参观博物馆。'),
      const ChatTurn('assistant', '可以按天气决定。'),
      for (var i = 0; i < 5; i++) ...[
        ChatTurn('user', '补充条件 $i'),
        ChatTurn('assistant', '已经了解条件 $i'),
      ],
    ];
    final result = input('回到最早提到的第二个安排。', history);
    expect(turns(result), hasLength(12));
    expect(turns(result).first['content'], contains('博物馆'));
    expect(result['context_truncation']['history_truncated'], false);
    expect(result['context_truncation']['messages_truncated'], false);
  });

  test(
    'long messages retain their beginning and final question with a marker',
    () {
      final history = [
        ChatTurn('assistant', '先讨论周末安排。${'中间说明' * 250}你想上午还是下午去？'),
      ];
      final result = input('下午吧。', history);
      final content = turns(result).single['content'] as String;
      expect(content, startsWith('先讨论周末安排。'));
      expect(content, endsWith('你想上午还是下午去？'));
      expect(content, contains('[中间内容已截断]'));
      expect(content.length, lessThanOrEqualTo(600));
      expect(result['context_truncation']['messages_truncated'], true);
      expect(result['context_truncation']['truncated_message_indices'], [0]);
    },
  );

  test('filters roles before selecting the newest 24 messages in order', () {
    final history = <ChatTurn>[];
    for (var i = 0; i < 30; i++) {
      history.add(ChatTurn(i.isEven ? 'user' : 'assistant', '对话 $i'));
      history.add(ChatTurn('system', '系统信息 $i'));
      history.add(ChatTurn('tool', '工具信息 $i'));
    }
    final result = input('继续。', history);
    expect(turns(result), hasLength(24));
    expect(turns(result).map((dynamic turn) => turn['content']), [
      for (var i = 6; i < 30; i++) '对话 $i',
    ]);
    expect(
      turns(
        result,
      ).every((dynamic turn) => ['user', 'assistant'].contains(turn['role'])),
      true,
    );
    final truncation = result['context_truncation'];
    expect(truncation['history_truncated'], true);
    expect(truncation['omitted_history_messages'], 6);
    expect(truncation['filtered_non_conversation_messages'], 60);
  });

  test('encoded JSON stays bounded when escaping greatly expands messages', () {
    final current = '${'\u0001' * 1997}原文!';
    final history = [
      for (var i = 0; i < 24; i++)
        ChatTurn(i.isEven ? 'user' : 'assistant', '$i:${'\u0000' * 590}'),
    ];
    final encoded = buildDialogueGuidanceInput(current, history);
    final result = jsonDecode(encoded) as Map<String, dynamic>;
    expect(encoded.length, lessThanOrEqualTo(20000));
    expect(result['user_message'], current);
    expect(turns(result), isNotEmpty);
    expect(turns(result).length, lessThan(24));
    expect(turns(result).last['content'], history.last.text);
    expect(
      result['context_truncation']['omitted_history_messages'],
      24 - turns(result).length,
    );
    expect(result['context_truncation']['history_truncated'], true);
    expect(result['context_truncation']['messages_truncated'], false);
  });

  test(
    'retained truncation indices remain correct after old messages drop',
    () {
      final result = input('', [
        for (var i = 0; i < 25; i++)
          ChatTurn('assistant', i == 2 ? '长' * 1000 : '短消息 $i'),
      ]);
      expect(turns(result), hasLength(24));
      expect(result['context_truncation']['omitted_history_messages'], 1);
      expect(result['context_truncation']['truncated_message_indices'], [1]);
    },
  );

  test('does not alter current text or the supplied history', () {
    const current = '  换行\n引号"和\\反斜线，照原样保留。  ';
    final history = <ChatTurn>[
      const ChatTurn('user', '我想了解语音功能。'),
      ChatTurn('assistant', '${'说明' * 500}先讲转写还是朗读？'),
      const ChatTurn('system', '不会传给导答的系统项'),
    ];
    final originalReferences = List<ChatTurn>.of(history);
    final originalText = history.map((turn) => turn.text).toList();
    final result = input(current, history);
    expect(result['user_message'], current);
    expect(history, originalReferences);
    expect(history.map((turn) => turn.text), originalText);
    for (var i = 0; i < history.length; i++) {
      expect(identical(history[i], originalReferences[i]), true);
    }
    (turns(result).first as Map<String, dynamic>)['content'] = '外部修改';
    expect(history.map((turn) => turn.text), originalText);
  });

  test('truncating emoji does not split UTF-16 pairs', () {
    final result = input('继续。', [ChatTurn('assistant', '🙂' * 500)]);
    final content = turns(result).single['content'] as String;
    expect(content.length, lessThanOrEqualTo(600));
    expect(utf8.decode(utf8.encode(content)), content);
    expect(content, startsWith('🙂'));
    expect(content, endsWith('🙂'));
  });

  test('supports empty history and rejects an oversized current message', () {
    final result = input('原样保留', const []);
    expect(turns(result), isEmpty);
    expect(result['context_truncation']['history_truncated'], false);
    expect(result['context_truncation']['omitted_history_messages'], 0);
    expect(result['context_truncation']['truncated_message_indices'], isEmpty);
    expect(
      () => buildDialogueGuidanceInput('敏感原文' * 501, const []),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.toString(),
          'does not expose user text',
          isNot(contains('敏感原文')),
        ),
      ),
    );
  });
}
