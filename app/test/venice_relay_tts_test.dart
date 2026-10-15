import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/venice_relay.dart';

void main() {
  final audio = [0xff, 0xfb, 0x90, 0x64, ...List.filled(124, 0)];
  Map<String, Object> payload() => {
    'model': 'tts-xai-v1',
    'input': '你好，这是中继朗读测试。',
    'voice': 'eve',
    'language': 'zh',
    'response_format': 'mp3',
    'speed': 1,
    'streaming': false,
  };
  Future<
    ({
      VeniceRelay relay,
      List<Map<String, Object>> events,
      Future<HttpClientResponse> Function(
        Map<String, Object>, {
        String token,
        String mime,
      })
      call,
    })
  >
  fixture(
    Future<void> Function(HttpRequest) handle, {
    Duration budget = const Duration(seconds: 3),
  }) async {
    final upstream = await HttpServer.bind('127.0.0.1', 0);
    upstream.listen(handle);
    final events = <Map<String, Object>>[];
    final relay = VeniceRelay(
      key: 'supplier-fixture',
      token: 'phone-fixture',
      upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
      onEvent: events.add,
      audioBudget: budget,
      retryDelay: Duration.zero,
    );
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen(relay.handle);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.close(force: true);
      await upstream.close(force: true);
    });
    Future<HttpClientResponse> call(
      Map<String, Object> data, {
      String token = 'phone-fixture',
      String mime = 'application/json',
    }) async {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/api/v1/audio/speech'),
      );
      req.headers.set('authorization', 'Bearer $token');
      req.headers.set('content-type', mime);
      req.add(utf8.encode(jsonEncode(data)));
      return req.close();
    }

    return (relay: relay, events: events, call: call);
  }

  test('relay forwards exact TTS payload with supplier bearer and binary MP3 response', () async {
    var calls = 0;
    final f = await fixture((r) async {
      calls++;
      expect(r.uri.path, '/api/v1/audio/speech');
      expect(r.headers.value('authorization'), 'Bearer supplier-fixture');
      expect(jsonDecode(await utf8.decoder.bind(r).join()), payload());
      r.response.headers.contentType = ContentType.binary;
      r.response.add(audio);
      await r.response.close();
    });
    final result = await f.call(payload());
    expect(result.statusCode, 200);
    expect(result.headers.contentType?.mimeType, 'audio/mpeg');
    expect(result.headers.value('x-aihaptics-relay-version'), '0.12.3');
    expect(
      result.headers.value('x-aihaptics-relay-capabilities')?.split(','),
      contains('speech'),
    );
    expect(result.headers.value('x-aihaptics-relay-attempts'), '1');
    expect(
      await result.fold<List<int>>([], (all, part) => all..addAll(part)),
      audio,
    );
    expect(calls, 1);
    expect(jsonEncode(f.events), isNot(contains('fixture')));
    expect(jsonEncode(f.events), isNot(contains('中继朗读测试')));
    expect(f.events.last['kind'], 'speech');
  });

  test(
    'streamed MP3 reaches phone before upstream completes without replay',
    () async {
      final release = Completer<void>();
      var calls = 0;
      final f = await fixture((r) async {
        calls++;
        final body = jsonDecode(await utf8.decoder.bind(r).join());
        expect(body['streaming'], true);
        r.response.headers.contentType = ContentType('audio', 'mpeg');
        r.response.bufferOutput = false;
        r.response.add(audio);
        await r.response.flush();
        await release.future;
        r.response.add(audio);
        await r.response.close();
      });
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final response = await f.call({...payload(), 'streaming': true});
      final parts = StreamIterator(response);
      expect(await parts.moveNext().timeout(const Duration(seconds: 2)), true);
      expect(parts.current, audio);
      release.complete();
      final tail = <int>[];
      while (await parts.moveNext()) {
        tail.addAll(parts.current);
      }
      expect(tail, audio);
      expect(calls, 1);
      expect(f.events.last['code'], 'stream_ok');
    },
  );

  test(
    'relay authenticates and validates TTS fields before upstream billing',
    () async {
      var calls = 0;
      final f = await fixture((r) async {
        calls++;
        await r.response.close();
      });
      final unauthorized = await f.call(payload(), token: 'wrong');
      expect(unauthorized.statusCode, 401);
      await unauthorized.drain<void>();
      final wrongMime = await f.call(payload(), mime: 'text/plain');
      expect(wrongMime.statusCode, 415);
      await wrongMime.drain<void>();
      for (final patch in <Map<String, Object>>[
        {'model': 'tts-other'},
        {'input': ''},
        {'input': '字' * 4097},
        {'voice': 'af_sky'},
        {'language': 'en'},
        {'response_format': 'wav'},
        {'streaming': 'true'},
        {'speed': 0.6},
        {'speed': 1.6},
        {'speed': '1'},
        {'extra': 'private'},
      ]) {
        final result = await f.call({...payload(), ...patch});
        expect(result.statusCode, 422, reason: '$patch');
        await result.drain<void>();
      }
      expect(calls, 0);
    },
  );

  for (final status in [302, 401, 402, 429, 502, 503, 504]) {
    test(
      'TTS HTTP $status is not replayed and supplier body stays private',
      () async {
        var calls = 0;
        final f = await fixture((r) async {
          calls++;
          await r.drain<void>();
          r.response.statusCode = status;
          r.response.headers.set('location', '/must-not-follow');
          r.response.write('private-supplier-response');
          await r.response.close();
        });
        final result = await f.call(payload());
        expect(result.statusCode, status);
        expect(result.headers.value('x-aihaptics-relay-attempts'), '1');
        expect(
          await utf8.decoder.bind(result).join(),
          isNot(contains('private')),
        );
        expect(calls, 1);
        expect(f.relay.active, 0);
      },
    );
  }

  for (final invalid in [false, true]) {
    test(
      'stream failure reports bounded audio detail invalid=$invalid',
      () async {
        var calls = 0;
        final f = await fixture((r) async {
          calls++;
          await r.drain<void>();
          r.response.headers.contentType = ContentType('audio', 'mpeg');
          if (invalid) r.response.add(List.filled(64, 65));
          await r.response.close();
        });
        final result = await f.call({...payload(), 'streaming': true});
        expect(result.statusCode, 502);
        expect(
          result.headers.value('x-aihaptics-relay-detail'),
          invalid ? 'invalid_mp3' : 'empty_stream',
        );
        await result.drain<void>();
        expect(calls, 1);
        expect(f.events.last['upstream_status'], 200);
        expect(f.events.last['upstream_bytes'], invalid ? 64 : 0);
        expect(f.events.last['response_started'], false);
        expect(jsonEncode(f.events), isNot(contains('fixture')));
      },
    );
  }
  for (final mislabeled in [false, true]) {
    test(
      'relay rejects successful HTTP with invalid audio, mislabeled=$mislabeled',
      () async {
        final f = await fixture((r) async {
          await r.drain<void>();
          r.response.headers.contentType = mislabeled
              ? ContentType('audio', 'mpeg')
              : ContentType.json;
          r.response.write('{"error":"private-supplier-payload"}');
          await r.response.close();
        });
        final result = await f.call(payload());
        expect(result.statusCode, 502);
        expect(
          result.headers.value('x-aihaptics-relay-error'),
          'upstream_audio_invalid',
        );
        expect(
          await utf8.decoder.bind(result).join(),
          isNot(contains('private')),
        );
      },
    );
  }

  test('relay reports oversized upstream audio as gateway failure without buffering it', () async {
    final f = await fixture((r) async {
      await r.drain<void>();
      r.response.headers.contentType = ContentType('audio', 'mpeg');
      r.response.contentLength = 16 * 1024 * 1024 + 1;
      r.response.add(audio);
      await r.response.flush();
    });
    final result = await f.call(payload());
    expect(result.statusCode, 502);
    expect(
      result.headers.value('x-aihaptics-relay-error'),
      'upstream_response_too_large',
    );
    await result.drain<void>();
  });

  test(
    'relay bounds TTS waiting and does not replay ambiguous timeout',
    () async {
      var calls = 0;
      final f = await fixture((r) async {
        calls++;
        await r.drain<void>();
      }, budget: const Duration(milliseconds: 150));
      final result = await f.call(payload());
      expect(result.statusCode, 504);
      expect(result.headers.value('x-aihaptics-relay-error'), 'timeout');
      await result.drain<void>();
      expect(calls, 1);
      expect(f.relay.active, 0);
    },
  );

  test('voice quota allows a full turn above the old 20-call limit but remains bounded', () async {
    var calls = 0;
    final f = await fixture((r) async {
      calls++;
      await r.drain<void>();
      r.response.headers.contentType = ContentType('audio', 'mpeg');
      r.response.add(audio);
      await r.response.close();
    });
    f.relay.starts.addAll(List.filled(20, DateTime.now()));
    final allowed = await f.call(payload());
    expect(allowed.statusCode, 200);
    await allowed.drain<void>();
    f.relay.starts.addAll(
      List.filled(
        VeniceRelay.maxStartsPerMinute - f.relay.starts.length,
        DateTime.now(),
      ),
    );
    final limited = await f.call(payload());
    expect(limited.statusCode, 429);
    await limited.drain<void>();
    expect(calls, 1);
    f.relay.starts.clear();
    f.relay.active = 2;
    final busy = await f.call(payload());
    expect(busy.statusCode, 429);
    await busy.drain<void>();
    expect(calls, 1);
  });
}
