import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';

Map<String, dynamic> completion(dynamic message, {dynamic reason = 'stop'}) => {
  'choices': [
    {'message': message, 'finish_reason': reason},
  ],
};

void main() {
  Future<ApiModelProvider> serve(
    Object? response, {
    ApiReplyMode mode = ApiReplyMode.chat,
    bool raw = false,
    bool hang = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      if (hang) return;
      request.response.write(raw ? response : jsonEncode(response));
      await request.response.close();
    });
    return ApiModelProvider(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1'),
      model: 'fixture',
      mode: mode,
      timeout: const Duration(milliseconds: 500),
    );
  }

  test(
    'chat preserves truncated text with a visible notice and no action',
    () async {
      final provider = await serve(
        completion({'content': '这是一段尚未写完的回复'}, reason: 'length'),
      );
      final reply = await provider.respond('你好', 'none');
      expect(reply.text, startsWith('这是一段尚未写完的回复'));
      expect(reply.text, contains('回复达到长度上限'));
      expect(reply.intent, {'action': 'noop'});
      expect(reply.continuation, isNull);
    },
  );

  for (final mode in [ApiReplyMode.tools, ApiReplyMode.json]) {
    test(
      '$mode rejects truncated replies even when text looks complete',
      () async {
        final provider = await serve(
          completion({
            'content': '{"text":"收到","intent":{"action":"noop"}}',
          }, reason: 'length'),
          mode: mode,
        );
        await expectLater(
          provider.respond('你好', 'none'),
          throwsA(
            isA<ModelServiceException>().having(
              (error) => error.message,
              'message',
              contains('被截断'),
            ),
          ),
        );
      },
    );
  }

  final invalidResponses = <(String, Object?, String)>[
    ('root', [], '顶层'),
    ('missing choices', {}, 'choices'),
    ('empty choices', {'choices': []}, 'choices'),
    ('wrong choices', {'choices': {}}, 'choices'),
    (
      'invalid choice',
      {
        'choices': [null],
      },
      '条目',
    ),
    ('invalid reason', completion({'content': '你好'}, reason: 123), '结束原因'),
    ('invalid message', completion('private-fixture'), 'message'),
    (
      'filtered',
      completion({'content': 'private-fixture'}, reason: 'content_filter'),
      '内容过滤',
    ),
    ('empty partial', completion({'content': ''}, reason: 'length'), '完整回复'),
    (
      'unexpected partial tool',
      completion({
        'content': 'private-fixture',
        'tool_calls': [
          {'id': 'unexpected'},
        ],
      }, reason: 'length'),
      '未允许',
    ),
  ];
  for (final (name, response, expected) in invalidResponses) {
    test('validates $name without echoing provider content', () async {
      final provider = await serve(response);
      await expectLater(
        provider.respond('你好', 'none'),
        throwsA(
          isA<ModelServiceException>()
              .having((error) => error.message, 'category', contains(expected))
              .having(
                (error) => error.message,
                'private payload',
                isNot(contains('private-fixture')),
              ),
        ),
      );
    });
  }

  test('invalid JSON gets a format error, not a connection error', () async {
    final provider = await serve('<html>private-fixture</html>', raw: true);
    await expectLater(
      provider.respond('你好', 'none'),
      throwsA(
        isA<ModelServiceException>().having(
          (error) => error.message,
          'message',
          '模型服务返回的响应不是有效 JSON。',
        ),
      ),
    );
  });

  test('chat timeout uses a chat-specific error', () async {
    final provider = await serve(null, hang: true);
    await expectLater(
      provider.respond('你好', 'none'),
      throwsA(
        isA<ModelServiceException>().having(
          (error) => error.message,
          'message',
          '等待模型回复超时，请稍后手动重试。',
        ),
      ),
    );
  });

  test('providers omitting finish reason remain compatible', () async {
    final provider = await serve({
      'choices': [
        {
          'message': {'content': '你好'},
        },
      ],
    });
    expect((await provider.respond('你好', 'none')).text, '你好');
  });

  test('malformed JSON mode content has a safe typed error', () async {
    final provider = await serve(
      completion({'content': '{private-fixture'}),
      mode: ApiReplyMode.json,
    );
    await expectLater(
      provider.respond('你好', 'none'),
      throwsA(
        isA<ModelServiceException>().having(
          (error) => error.message,
          'message',
          '兼容 JSON 模式返回的内容不是有效 JSON。',
        ),
      ),
    );
  });
}
