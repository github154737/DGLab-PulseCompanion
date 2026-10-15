import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/chat_stream.dart';
import 'package:haptics_lab/speech_output.dart';

String event(Map<String, Object?> delta, [String? finish]) =>
    'data: ${jsonEncode({
      'choices': [
        {'delta': delta, 'finish_reason': finish},
      ],
    })}\n\n';

void main() {
  test('SSE exposes Chinese text before EOF and ignores reasoning', () async {
    final input = StreamController<List<int>>();
    final first = Completer<void>();
    final seen = <String>[];
    final result = readChatStream(
      input.stream,
      onText: (text) {
        seen.add(text);
        if (!first.isCompleted) first.complete();
      },
    );
    for (final byte in utf8.encode(
      event({'reasoning_content': 'hidden', 'content': '你好。'}),
    )) {
      input.add([byte]);
    }
    await first.future.timeout(const Duration(seconds: 2));
    expect(seen, ['你好。']);
    input.add(
      utf8.encode('${event({'content': '再见。'}, 'stop')}data: [DONE]\n\n'),
    );
    await input.close();
    expect((await result).text, '你好。再见。');
  });

  for (final bad in [
    event({'content': '你好。'}, 'stop'),
    event({'tool_calls': []}),
    event({'content': 'a' * 4097}, 'stop'),
    event({'content': '你好。'}, 'content_filter'),
    'data: {broken}\n\n',
  ]) {
    test(
      'malformed or incomplete stream fails instead of successful reply ${bad.length}',
      () async {
        await expectLater(
          readChatStream(Stream.value(utf8.encode(bad)), onText: (_) {}),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'first long clause emits before full stop without tiny or numeric splits',
    () {
      final split = SpeechSentences();
      const first = '我们可以先慢慢聊一会今天发生的事情，';
      expect(split.add(first), [first]);
      final full =
          '$first'
          '然后，再继续。';
      expect(split.add(full), ['然后，再继续。']);
      expect(split.add(full, complete: true), isEmpty);
      expect(SpeechSentences().add('好的，继续'), isEmpty);
      expect(SpeechSentences().add('金额是123,456.78元'), isEmpty);
      expect(SpeechSentences().add('[${'隐藏内容，' * 30}'), isEmpty);
    },
  );

  test('sentence boundaries emit once; split machine blocks never spoken', () {
    final split = SpeechSentences();
    expect(split.add('你好'), isEmpty);
    expect(split.add('你好。接着'), ['你好。']);
    expect(split.add('你好。接着聊。['), ['接着聊。']);
    expect(split.add('你好。接着聊。[[CTRL {"a":5}]]'), isEmpty);
    final rest = split.add('你好。接着聊。[[CTRL {"a":5}]]完成', complete: true);
    expect(rest.map(SpeechOutput.spokenText).toList(), ['完成']);
    expect(split.add('你好。接着聊。[[CTRL {"a":5}]]完成', complete: true), isEmpty);
    expect(() => split.add('替换旧文本'), throwsFormatException);
  });
}
