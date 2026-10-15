import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/dialogue_guidance.dart';
import 'package:haptics_lab/venice_control_provider.dart';
import 'package:haptics_lab/venice_wave_session.dart';

Map<String, dynamic> validGuidance() => {
  'intent_summary': '用户确认上一轮的问题。',
  'reply_focus': ['承接上一轮的具体话题。', '避免重复已经说明的信息。'],
  'context_anchor': '上轮讨论了会话记忆。',
  'ask_clarification': false,
};

void main() {
  test('guidance decodes the exact schema and exposes immutable fields', () {
    final source = validGuidance();
    final guidance = DialogueGuidance.decode(jsonEncode(source));
    expect(guidance.intentSummary, source['intent_summary']);
    expect(guidance.replyFocus, source['reply_focus']);
    expect(guidance.contextAnchor, source['context_anchor']);
    expect(guidance.askClarification, isFalse);
    expect(guidance.toJson(), source);
    expect(() => guidance.replyFocus.add('new'), throwsUnsupportedError);
    final snapshot = guidance.toJson();
    (snapshot['reply_focus'] as List<String>).clear();
    snapshot['intent_summary'] = 'changed';
    expect(guidance.replyFocus, hasLength(2));
    expect(guidance.intentSummary, source['intent_summary']);
  });

  test('guidance accepts no context anchor and an empty focus list', () {
    final source = validGuidance()
      ..['reply_focus'] = <String>[]
      ..['context_anchor'] = ''
      ..['ask_clarification'] = true;
    final guidance = DialogueGuidance.decode(jsonEncode(source));
    expect(guidance.contextAnchor, isEmpty);
    expect(guidance.replyFocus, isEmpty);
    expect(guidance.askClarification, isTrue);
  });

  test('guidance rejects prose, markdown, incomplete JSON and nonobjects', () {
    for (final source in [
      '',
      'Here is the plan: ${jsonEncode(validGuidance())}',
      '```json\n${jsonEncode(validGuidance())}\n```',
      '{"intent_summary":',
      '[]',
      'null',
      'true',
    ]) {
      expect(() => DialogueGuidance.decode(source), throwsFormatException);
    }
  });

  test('guidance rejects missing, unknown, and device action fields', () {
    for (final key in validGuidance().keys) {
      final source = validGuidance()..remove(key);
      expect(
        () => DialogueGuidance.decode(jsonEncode(source)),
        throwsFormatException,
      );
    }
    for (final extra in [
      'action',
      'a',
      'b',
      'waveform_id',
      'reasoning',
      'reply',
    ]) {
      final source = validGuidance()..[extra] = 'unexpected';
      expect(
        () => DialogueGuidance.decode(jsonEncode(source)),
        throwsFormatException,
      );
    }
    final replaced = validGuidance()
      ..remove('context_anchor')
      ..['action'] = 'set';
    expect(
      () => DialogueGuidance.decode(jsonEncode(replaced)),
      throwsFormatException,
    );
  });

  test('guidance rejects wrong field types and empty required text', () {
    final invalidFields = <String, List<dynamic>>{
      'intent_summary': [null, 1, true, {}, [], '', '   '],
      'reply_focus': [
        null,
        'text',
        {},
        [1],
        [null],
        [''],
        ['   '],
      ],
      'context_anchor': [null, 1, true, {}, []],
      'ask_clarification': [null, 0, 1, 'false', {}, []],
    };
    for (final entry in invalidFields.entries) {
      for (final value in entry.value) {
        final source = validGuidance()..[entry.key] = value;
        expect(
          () => DialogueGuidance.decode(jsonEncode(source)),
          throwsFormatException,
          reason: 'Invalid ${entry.key} type/value must not be coerced',
        );
      }
    }
  });

  test('guidance enforces text, focus count and encoded payload bounds', () {
    final boundaryText = '字' * DialogueGuidance.maxFieldLength;
    final boundary = validGuidance()
      ..['intent_summary'] = boundaryText
      ..['context_anchor'] = boundaryText
      ..['reply_focus'] = [boundaryText, boundaryText, boundaryText];
    expect(
      DialogueGuidance.decode(jsonEncode(boundary)).replyFocus,
      hasLength(3),
    );
    for (final field in ['intent_summary', 'context_anchor', 'reply_focus']) {
      final source = validGuidance()
        ..[field] = field == 'reply_focus'
            ? ['$boundaryText字']
            : '$boundaryText字';
      expect(
        () => DialogueGuidance.decode(jsonEncode(source)),
        throwsFormatException,
      );
    }
    expect(
      () => DialogueGuidance.decode(
        jsonEncode(validGuidance()..['reply_focus'] = ['a', 'b', 'c', 'd']),
      ),
      throwsFormatException,
    );
    // Escaped strings fit their individual limits but exceed the total budget.
    final escaped = '"' * DialogueGuidance.maxFieldLength;
    final oversized = validGuidance()
      ..['intent_summary'] = escaped
      ..['context_anchor'] = escaped
      ..['reply_focus'] = [escaped, escaped, escaped];
    expect(jsonEncode(oversized).length, greaterThan(1200));
    expect(
      () => DialogueGuidance.decode(jsonEncode(oversized)),
      throwsFormatException,
    );
  });

  test('guidance failures never include the raw response', () {
    const secret = 'private-user-text-and-key';
    try {
      DialogueGuidance.decode(secret);
      fail('invalid JSON must fail');
    } on FormatException catch (error) {
      expect(error.toString(), isNot(contains(secret)));
      expect(error.source, isNull);
    }
  });

  test(
    'GLM guidance request uses its own prompt and bounded JSON settings',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bodies = <Map<String, dynamic>>[];
      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer local-fixture');
        bodies.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'content': jsonEncode(validGuidance())},
              },
            ],
          }),
        );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}/v1');
      final provider = createDialogueGuidanceProvider(
        endpoint: endpoint,
        apiKey: 'local-fixture',
      );
      addTearDown(() async {
        provider.cancel();
        await server.close(force: true);
      });
      expect(provider.mode, ApiReplyMode.chat);
      expect(provider.diagnosticPurpose, ApiDiagnosticPurpose.dialogueGuidance);
      expect(provider.timeout, const Duration(seconds: 8));
      expect(provider.systemPromptOverride, dialogueGuidancePrompt);
      final result = await provider.respond('请承接前文回答这个问题。', '');
      expect(DialogueGuidance.decode(result.text).toJson(), validGuidance());
      final body = bodies.single;
      expect(body['model'], veniceControlModel);
      expect(body['max_tokens'], 512);
      expect(body['temperature'], .2);
      expect(body['stream'], false);
      expect(body['response_format'], {'type': 'json_object'});
      expect(body.containsKey('tools'), false);
      expect(body.containsKey('reasoning'), false);
      expect(body['messages'], [
        {'role': 'system', 'content': dialogueGuidancePrompt},
        {'role': 'user', 'content': '请承接前文回答这个问题。'},
      ]);
      final control = createVeniceControlProvider(
        endpoint: endpoint,
        apiKey: 'local-fixture',
        state: {'a': 1, 'b': 2},
      );
      addTearDown(control.cancel);
      expect(control.diagnosticPurpose, ApiDiagnosticPurpose.automatic);
      expect(
        control.systemPromptOverride,
        '${VeniceWaveSession.plannerPrompt}\nLocal state: {"a":1,"b":2}',
      );
      expect(
        provider.systemPromptOverride,
        isNot(control.systemPromptOverride),
      );
    },
  );
}
