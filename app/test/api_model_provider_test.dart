import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/chat_context.dart';

Map<String, dynamic> messageResponse(
  Map<String, dynamic> message, {
  String reason = 'stop',
}) => {
  'choices': [
    {'finish_reason': reason, 'message': message},
  ],
};
Map<String, dynamic> toolCall({
  String name = 'set_gain',
  String args = '{"gain":0.6}',
}) => {
  'id': 'call_fixture',
  'type': 'function',
  'function': {'name': name, 'arguments': args},
};

void main() {
  test('endpoint normalization and transport validation', () {
    final provider = ApiModelProvider(
      endpoint: Uri.parse('https://example.com/v1'),
      model: 'fixture',
    );
    expect(
      provider.endpoint.toString(),
      'https://example.com/v1/chat/completions',
    );
    for (final url in [
      'http://remote.example/v1',
      'https://user:secret@example.com/v1',
      'https://example.com/v1?key=x',
      'https://example.com/#x',
      'file:///tmp',
    ]) {
      expect(
        () => ApiModelProvider(endpoint: Uri.parse(url), model: 'fixture'),
        throwsA(isA<ModelServiceException>()),
      );
    }
  });

  test('request limits reject invalid timeout and token budget', () {
    for (final timeout in [Duration.zero, const Duration(seconds: 121)]) {
      expect(
        () => ApiModelProvider(
          endpoint: Uri.parse('https://example.com'),
          model: 'fixture',
          timeout: timeout,
        ),
        throwsA(isA<ModelServiceException>()),
      );
    }
    for (final tokens in [0, 2401]) {
      expect(
        () => ApiModelProvider(
          endpoint: Uri.parse('https://example.com'),
          model: 'fixture',
          maxTokens: tokens,
        ),
        throwsA(isA<ModelServiceException>()),
      );
    }
  });

  test('tool cycle sends the actual execution result and does not execute another action', () async {
    final requests = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      expect(req.headers.value('authorization'), 'Bearer fixture-token');
      final body = jsonDecode(
        await utf8.decoder.bind(req).join(),
      ) as Map<String, dynamic>;
      requests.add(body);
      req.response.write(
        jsonEncode(
          messageResponse(
            requests.length == 1
                ? {
                    'role': 'assistant',
                    'content': null,
                    'tool_calls': [toolCall()],
                  }
                : {'role': 'assistant', 'content': '收到，已经按你的选择调整。'},
          ),
        ),
      );
      await req.response.close();
    });
    final provider = ApiModelProvider(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1'),
      model: 'fixture',
      apiKey: 'fixture-token',
      maxTokens: 2400,
      timeout: const Duration(seconds: 60),
    );
    final reply = await provider.respond(
      '强一点',
      'sim_single',
      context: const ChatContext(playing: true, remainingMs: 20000),
    );
    expect(reply.intent, {'action': 'set_gain', 'gain': 0.6});
    final text = await provider.finishToolCall(reply, {
      'ok': true,
      'gain_target': 0.6,
      'simulation_only': true,
    });
    expect(text, contains('调整'));
    expect(requests.first['parallel_tool_calls'], false);
    expect(requests.first['temperature'], 0.8);
    expect(requests.every((request) => request['max_tokens'] == 2400), true);
    expect(
      (requests.first['messages'] as List).first['content'],
      contains('never require a word'),
    );
    expect(requests.last.containsKey('tools'), false);
    final resultMessage = (requests.last['messages'] as List).last;
    expect(resultMessage['role'], 'tool');
    expect(resultMessage['tool_call_id'], 'call_fixture');
    expect(jsonDecode(resultMessage['content'])['gain_target'], 0.6);
  });

  for (final scenario in [
    'multiple',
    'unknown',
    'truncated',
    'unauthorized',
    'bad_args',
    'followup_action',
    'redirect',
    'auth_error',
    'oversize',
    'timeout',
    'cancel',
  ]) {
    test('rejects $scenario without executing or falling back', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var seen = 0;
      final started = Completer<void>();
      server.listen((req) async {
        seen++;
        await req.drain<void>();
        if (!started.isCompleted) started.complete();
        if (scenario == 'timeout' || scenario == 'cancel') return;
        if (scenario == 'redirect') {
          req.response.statusCode = 302;
          req.response.headers.set(
            'location',
            'http://127.0.0.1:${server.port}/elsewhere',
          );
        } else if (scenario == 'auth_error') {
          req.response.statusCode = 401;
          req.response.write(
            'provider body should never be echoed fixture-token',
          );
        } else if (scenario == 'oversize') {
          req.response.write('x' * 70000);
        } else {
          req.response.write(
            jsonEncode(
              messageResponse({
                'content': null,
                'tool_calls': [
                  toolCall(
                    name: scenario == 'unknown' ? 'authorize' : 'set_gain',
                    args: scenario == 'bad_args'
                        ? '{"action":"stop"}'
                        : '{"gain":0.6}',
                  ),
                  if (scenario == 'multiple') toolCall(),
                ],
              }, reason: scenario == 'truncated' ? 'length' : 'tool_calls'),
            ),
          );
        }
        await req.response.close();
      });
      final provider = ApiModelProvider(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1'),
        model: 'fixture',
        timeout: const Duration(milliseconds: 300),
      );
      final future = provider.respond(
        '强一点',
        'sim_single',
        context: ChatContext(controlAllowed: scenario != 'unauthorized'),
      );
      if (scenario == 'followup_action') {
        final reply = await future;
        await expectLater(
          provider.finishToolCall(reply, {'ok': false}),
          throwsA(isA<ModelServiceException>()),
        );
      } else {
        final expectation = expectLater(
          future,
          throwsA(isA<ModelServiceException>()),
        );
        if (scenario == 'cancel') {
          await started.future;
          provider.cancel();
        }
        await expectation;
      }
      expect(seen, scenario == 'followup_action' ? 2 : 1);
    });
  }

  test('plain chat has no tools when unauthorized and JSON compatibility is explicit', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join());
      expect(body.containsKey('tools'), false);
      final jsonMode = body.containsKey('response_format');
      req.response.write(
        jsonEncode(
          messageResponse({
            'content': jsonMode
                ? jsonEncode({
                    'text': '你好',
                    'intent': {'action': 'noop'},
                  })
                : '你好，今天过得怎么样？',
          }),
        ),
      );
      await req.response.close();
    });
    for (final mode in ApiReplyMode.values) {
      final p = ApiModelProvider(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1'),
        model: 'fixture',
        mode: mode,
      );
      expect(
        (await p.respond(
          '你好',
          'none',
          context: const ChatContext(controlAllowed: false),
        )).intent['action'],
        'noop',
      );
    }
  });
}
