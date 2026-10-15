import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/chat_context.dart';

import '../tool/venice_relay.dart';

String event(String text, [String? finish]) =>
    'data: ${jsonEncode({
      'choices': [
        {
          'delta': {'content': text},
          'finish_reason': finish,
        },
      ],
    })}\n\n';

void main() {
  for (final interrupt in [false, true]) {
    test(
      'SSE through relay exposes first text, interrupt=$interrupt',
      () async {
        final upstream = await HttpServer.bind('127.0.0.1', 0);
        final release = Completer<void>();
        final first = Completer<void>();
        var calls = 0;
        final seen = <String>[];
        upstream.listen((r) async {
          calls++;
          final body = jsonDecode(await utf8.decoder.bind(r).join());
          expect(body['stream'], true);
          expect(body.containsKey('tools'), false);
          r.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          r.response.bufferOutput = false;
          r.response.write(event('你好。'));
          await r.response.flush();
          await release.future;
          if (interrupt) {
            r.response.addError(const HttpException('fixture_interrupted'));
            try {
              await r.response.close();
            } catch (_) {}
          } else {
            r.response.write('${event('测试完成。', 'stop')}data: [DONE]\n\n');
            await r.response.close();
          }
        });
        final relay = VeniceRelay(
          key: 'supplier-fixture',
          token: 'phone-fixture',
          upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
        );
        final server = await HttpServer.bind('127.0.0.1', 0);
        server.listen(relay.handle);
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await server.close(force: true);
          await upstream.close(force: true);
        });
        final provider = ApiModelProvider(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
          model: 'venice-uncensored-1-2',
          apiKey: 'phone-fixture',
          mode: ApiReplyMode.chat,
          onText: (text) {
            seen.add(text);
            if (!first.isCompleted) first.complete();
          },
        );
        final response = provider.respond(
          '你好',
          'none',
          context: const ChatContext(controlAllowed: false),
        );
        final expectation = interrupt
            ? expectLater(response, throwsA(isA<ModelServiceException>()))
            : null;
        await first.future.timeout(const Duration(seconds: 2));
        expect(seen, ['你好。']);
        release.complete();
        if (interrupt) {
          await expectation;
        } else {
          expect((await response).text, '你好。测试完成。');
        }
        expect(calls, 1, reason: 'never replay a partially delivered response');
      },
    );
  }
}
