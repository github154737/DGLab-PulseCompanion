import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/chat_context.dart';

void main() {
  test('Venice base URL preserves api prefix', () {
    expect(
      ApiModelProvider.normalizeEndpoint(
        Uri.parse('https://api.venice.ai/api/v1/'),
      ).toString(),
      'https://api.venice.ai/api/v1/chat/completions',
    );
  });

  test(
    'chat mode excludes tools, device context and image even if authorized',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        expect(body.containsKey('tools'), false);
        expect(body.containsKey('response_format'), false);
        expect(jsonEncode(body), isNot(contains('private-device-state')));
        expect(body['messages'].last['content'], '你好');
        expect(body['messages'][1]['role'], 'system');
        expect(body['messages'][1]['content'], contains('星禾'));
        expect(body['messages'][2]['content'], '我喜欢简短回复');
        req.response.write(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'content': '你好，今天过得怎么样？'},
              },
            ],
          }),
        );
        await req.response.close();
      });
      final provider = ApiModelProvider(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        model: 'fixture',
        mode: ApiReplyMode.chat,
      );
      final reply = await provider.respond(
        '你好',
        'private-device-state',
        context: const ChatContext(
          aiName: '星禾',
          observation: 'private-device-state',
          imageData: 'data:image/jpeg;base64,abc',
          history: [ChatTurn('user', '我喜欢简短回复')],
        ),
      );
      expect(reply.intent, {'action': 'noop'});
    },
  );

  test(
    'chat mode rejects unexpected tool calls and never retries 402',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var count = 0;
      server.listen((req) async {
        await req.drain<void>();
        count++;
        if (count == 1) {
          req.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': null,
                    'tool_calls': [
                      {'id': 'unexpected'},
                    ],
                  },
                },
              ],
            }),
          );
        } else {
          req.response.statusCode = 402;
          req.response.write('fixture-private-secret');
        }
        await req.response.close();
      });
      final provider = ApiModelProvider(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1'),
        model: 'fixture',
        mode: ApiReplyMode.chat,
      );
      await expectLater(
        provider.respond('你好', ''),
        throwsA(isA<ModelServiceException>()),
      );
      await expectLater(
        provider.respond('你好', ''),
        throwsA(
          isA<ModelServiceException>().having(
            (e) => e.message,
            'balance',
            contains('余额不足'),
          ),
        ),
      );
      expect(count, 2);
    },
  );
}
