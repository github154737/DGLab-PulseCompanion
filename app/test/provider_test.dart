import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/chat_context.dart';

void main() {
  test(
    'rejects remote endpoints and embedded credentials before connecting',
    () {
      for (final url in [
        'https://example.com/v1/chat/completions',
        'http://192.168.1.2:1234',
        'http://user:secret@127.0.0.1:1234',
      ]) {
        expect(
          () => LocalModelProvider(endpoint: Uri.parse(url), model: 'test'),
          throwsArgumentError,
        );
      }
    },
  );
  test('local HTTP adapter sends a non-streaming request and parses a complete intent', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestSeen = Completer<Map<String, dynamic>>();
    server.listen((req) async {
      requestSeen.complete(
        jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>,
      );
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'text': '保持安静',
                  'intent': {'action': 'noop'},
                }),
              },
            },
          ],
        }),
      );
      await req.response.close();
    });
    final provider = LocalModelProvider(
      endpoint: Uri.parse(
        'http://127.0.0.1:${server.port}/v1/chat/completions',
      ),
      model: 'test',
    );
    final result = await provider.respond(
      'test prompt',
      'sim_single',
      context: ChatContext(
        controlAllowed: false,
        style: '俏皮',
        history: [
          const ChatTurn('system', 'untrusted role'),
          for (var i = 0; i < 20; i++)
            ChatTurn(i == 19 ? 'system' : 'user', 'history $i'),
          ChatTurn('assistant', 'x' * 3000),
        ],
      ),
    );
    expect(result.intent, {'action': 'noop'});
    final request = await requestSeen.future;
    expect(request['stream'], false);
    final messages = request['messages'] as List;
    expect(messages.last['content'], 'test prompt');
    expect(messages.where((m) => m['role'] == 'system').length, 1);
    expect(messages.first['content'], contains('intent MUST be noop'));
    expect(messages.length, 13);
    expect(messages[messages.length - 2]['content'].length, 2000);
    expect(messages.any((m) => m['content'] == 'history 0'), false);
  });
  test(
    'demo chat does not require control and gain uses current context',
    () async {
      const fake = FakeModelProvider(delay: Duration.zero);
      expect(
        (await fake.respond(
          '强一点',
          'sim_single',
          context: const ChatContext(controlAllowed: false),
        )).intent,
        {'action': 'noop'},
      );
      expect((await fake.respond('今天想聊聊天', 'sim_single')).intent, {
        'action': 'noop',
      });
      expect(
        (await fake.respond(
          '强一点',
          'sim_single',
          context: const ChatContext(gain: 0.6),
        )).intent['gain'],
        closeTo(0.7, 1e-8),
      );
      expect(
        (await fake.respond(
          '弱一点',
          'sim_single',
          context: const ChatContext(gain: 0.05),
        )).intent['gain'],
        0,
      );
      expect(
        (await fake.respond(
          '播放导入波形',
          'sim_dglab',
          context: const ChatContext(waveforms: ['approved']),
        )).intent,
        {
          'action': 'play_waveform',
          'device_alias': 'sim_dglab',
          'waveform_id': 'approved',
        },
      );
    },
  );
  for (final scenario in [
    'malformed',
    'oversize',
    'redirect',
    'failure',
    'timeout',
  ]) {
    test('rejects $scenario responses without fallback', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var count = 0;
      server.listen((req) async {
        count++;
        await req.drain<void>();
        if (scenario == 'timeout') {
          return;
        }
        if (scenario == 'redirect') {
          req.response.statusCode = 302;
          req.response.headers.set(
            'location',
            'http://127.0.0.1:${server.port}/other',
          );
        } else if (scenario == 'failure') {
          req.response.statusCode = 503;
        } else {
          req.response.write(scenario == 'oversize' ? 'x' * 70000 : '{');
        }
        await req.response.close();
      });
      final provider = LocalModelProvider(
        endpoint: Uri.parse(
          'http://127.0.0.1:${server.port}/v1/chat/completions',
        ),
        model: 'test',
        timeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        provider.respond('test', 'sim_single'),
        throwsA(isA<Exception>()),
      );
      expect(count, 1);
    });
  }
}
