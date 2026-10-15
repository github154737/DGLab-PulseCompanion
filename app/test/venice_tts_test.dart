import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/network_diagnostics.dart';
import 'package:haptics_lab/venice_tts.dart';

Uint8List mp3Fixture() =>
    Uint8List.fromList([0xff, 0xfb, 0x90, 0x64, ...List.filled(124, 0)]);

void main() {
  Future<({HttpServer server, Uri endpoint})> fixture(
    Future<void> Function(HttpRequest) handle,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen(handle);
    return (
      server: server,
      endpoint: Uri.parse(
        'http://127.0.0.1:${server.port}/api/v1/audio/speech',
      ),
    );
  }

  test(
    'sends xAI Chinese female MP3 request and reads binary audio exactly',
    () async {
      final bytes = mp3Fixture();
      var calls = 0;
      final f = await fixture((r) async {
        calls++;
        expect(r.headers.value('authorization'), 'Bearer fixture-only');
        expect(r.headers.contentType?.mimeType, 'application/json');
        expect(r.headers.value('accept'), 'audio/mpeg');
        final payload = jsonDecode(await utf8.decoder.bind(r).join());
        expect(payload, {
          'model': 'tts-xai-v1',
          'input': '你好，这是语音输出测试。',
          'voice': 'eve',
          'language': 'zh',
          'response_format': 'mp3',
          'speed': 1.0,
          'streaming': false,
        });
        r.response.headers.contentType = ContentType('audio', 'mpeg');
        r.response.add(bytes);
        await r.response.close();
      });
      final client = VeniceTtsClient(
        apiKey: 'fixture-only',
        endpoint: f.endpoint,
      );
      expect(await client.synthesize('  你好，这是语音输出测试。  '), bytes);
      expect(calls, 1);
      expect(NetworkTrace.report, isNot(contains('这是语音输出测试')));
      expect(NetworkTrace.report, isNot(contains('fixture-only')));
    },
  );

  test('TTS delivers first validated MP3 bytes before upstream EOF', () async {
    final release = Completer<void>();
    final first = Completer<void>();
    final received = <int>[];
    final bytes = mp3Fixture();
    final f = await fixture((r) async {
      final body = jsonDecode(await utf8.decoder.bind(r).join());
      expect(body['streaming'], true);
      r.response.headers.contentType = ContentType('audio', 'mpeg');
      r.response.bufferOutput = false;
      r.response.add(bytes);
      await r.response.flush();
      await release.future;
      r.response.add(bytes);
      await r.response.close();
    });
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final client = VeniceTtsClient(
      apiKey: 'fixture-only',
      endpoint: f.endpoint,
    );
    client.onAudioChunk = (part) async {
      received.addAll(part);
      if (!first.isCompleted) first.complete();
    };
    final complete = client.synthesize('你好。');
    await first.future.timeout(const Duration(seconds: 2));
    expect(received, bytes);
    release.complete();
    expect(await complete, [...bytes, ...bytes]);
    expect(received, [...bytes, ...bytes]);
  });

  test(
    'invalid settings and long text fail before sending a paid request',
    () async {
      var calls = 0;
      final f = await fixture((r) async {
        calls++;
        await r.response.close();
      });
      final client = VeniceTtsClient(
        apiKey: 'fixture-only',
        endpoint: f.endpoint,
      );
      for (final text in ['', '   ', '字' * 4097]) {
        await expectLater(
          client.synthesize(text),
          throwsA(isA<ModelServiceException>()),
        );
      }
      for (final voice in ['unknown', 'Eve', 'af_sky']) {
        await expectLater(
          client.synthesize('你好', voice: voice),
          throwsA(isA<ModelServiceException>()),
        );
      }
      for (final speed in [double.nan, double.infinity, 0.69, 1.51]) {
        await expectLater(
          client.synthesize('你好', speed: speed),
          throwsA(isA<ModelServiceException>()),
        );
      }
      expect(calls, 0);
    },
  );

  test('unsafe endpoints and header injection are rejected', () {
    for (final address in [
      'http://api.venice.ai/api/v1/audio/speech',
      'https://api.venice.ai.evil.invalid/api/v1/audio/speech',
      'https://api.venice.ai/anything',
      'https://api.venice.ai:444/api/v1/audio/speech',
      'https://user@api.venice.ai/api/v1/audio/speech',
      'https://api.venice.ai/api/v1/audio/speech?key=x',
      'https://api.venice.ai/api/v1/audio/speech#fragment',
    ]) {
      expect(
        () => VeniceTtsClient(
          apiKey: 'fixture-only',
          endpoint: Uri.parse(address),
        ),
        throwsA(isA<ModelServiceException>()),
      );
    }
    for (final key in ['', ' ', 'bad\nkey', 'bad\rkey', 'x' * 4097]) {
      expect(
        () => VeniceTtsClient(apiKey: key),
        throwsA(isA<ModelServiceException>()),
      );
    }
  });

  test(
    'errors stay sanitized and all paid failures are single attempt',
    () async {
      var calls = 0, status = 502;
      final f = await fixture((r) async {
        calls++;
        await r.drain<void>();
        r.response.statusCode = status;
        r.response.headers.set('location', '/must-not-follow');
        r.response.write('private-key-and-chat-fixture');
        await r.response.close();
      });
      for (final code in [
        400,
        401,
        402,
        403,
        404,
        413,
        415,
        422,
        429,
        302,
        500,
        502,
        503,
        504,
      ]) {
        status = code;
        final client = VeniceTtsClient(
          apiKey: 'fixture-only',
          endpoint: f.endpoint,
        );
        await expectLater(
          client.synthesize('你好'),
          throwsA(
            isA<ModelServiceException>().having(
              (e) => e.message,
              'sanitized',
              isNot(contains('private-key')),
            ),
          ),
        );
      }
      expect(calls, 14);
    },
  );

  test(
    'JSON, HTML, empty, truncated or mislabeled audio cannot be played',
    () async {
      var body = <int>[];
      var mime = ContentType.json;
      final f = await fixture((r) async {
        await r.drain<void>();
        r.response.headers.contentType = mime;
        r.response.add(body);
        await r.response.close();
      });
      for (final sample in [
        (mime: ContentType.json, bytes: utf8.encode('{"error":"private"}')),
        (mime: ContentType.html, bytes: utf8.encode('<html>error</html>')),
        (mime: ContentType('audio', 'mpeg'), bytes: <int>[]),
        (
          mime: ContentType('audio', 'mpeg'),
          bytes: utf8.encode('{"error":"not-mp3-even-if-labeled-audio"}'),
        ),
        (mime: ContentType('audio', 'mpeg'), bytes: [0xff, 0xfb, 0x90, 0x64]),
        (
          mime: ContentType('audio', 'mpeg'),
          bytes: [0x49, 0x44, 0x33, 0x09, ...List.filled(40, 0)],
        ),
      ]) {
        body = sample.bytes;
        mime = sample.mime;
        final client = VeniceTtsClient(
          apiKey: 'fixture-only',
          endpoint: f.endpoint,
        );
        await expectLater(
          client.synthesize('你好'),
          throwsA(isA<ModelServiceException>()),
        );
      }
      body = mp3Fixture();
      mime = ContentType.binary;
      expect(
        await VeniceTtsClient(
          apiKey: 'fixture-only',
          endpoint: f.endpoint,
        ).synthesize('你好'),
        body,
      );
    },
  );

  test(
    'oversized Content-Length is rejected without downloading whole file',
    () async {
      final f = await fixture((r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType('audio', 'mpeg');
        r.response.contentLength = veniceTtsMaxBytes + 1;
        r.response.add(mp3Fixture());
        await r.response.flush();
      });
      final client = VeniceTtsClient(
        apiKey: 'fixture-only',
        endpoint: f.endpoint,
      );
      await expectLater(
        client.synthesize('你好'),
        throwsA(
          isA<ModelServiceException>().having(
            (e) => e.message,
            'size',
            contains('过大'),
          ),
        ),
      );
    },
  );

  test('cancel aborts stalled request and is terminal without retry', () async {
    var calls = 0;
    final seen = Completer<void>();
    final f = await fixture((r) async {
      calls++;
      await r.drain<void>();
      seen.complete();
    });
    final client = VeniceTtsClient(
      apiKey: 'fixture-only',
      endpoint: f.endpoint,
    );
    final result = expectLater(
      client.synthesize('你好'),
      throwsA(
        isA<ModelServiceException>().having(
          (e) => e.message,
          'cancel',
          contains('取消'),
        ),
      ),
    );
    await seen.future;
    await expectLater(
      client.synthesize('不能并发'),
      throwsA(isA<ModelServiceException>()),
    );
    client.cancel();
    await result;
    await expectLater(
      client.synthesize('不再发送'),
      throwsA(isA<ModelServiceException>()),
    );
    expect(calls, 1);
  });

  test('timeout is explicit and never starts another paid request', () async {
    var calls = 0;
    final f = await fixture((r) async {
      calls++;
      await r.drain<void>();
    });
    final client = VeniceTtsClient(
      apiKey: 'fixture-only',
      endpoint: f.endpoint,
      timeout: const Duration(milliseconds: 150),
    );
    await expectLater(
      client.synthesize('你好'),
      throwsA(
        isA<ModelServiceException>().having(
          (e) => e.message,
          'timeout',
          contains('超时'),
        ),
      ),
    );
    expect(calls, 1);
  });
}
