import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/venice_relay.dart';

void main() {
  Future<
    ({
      VeniceRelay relay,
      Future<HttpClientResponse> Function(bool) call,
      List<String> received,
      List<Map<String, Object>> events,
      void Function() disconnect,
    })
  >
  fixture(
    List<int> statuses, {
    bool failConnect = false,
    bool stall = false,
    bool stallRead = false,
  }) async {
    final upstream = await HttpServer.bind('127.0.0.1', 0);
    final received = <String>[], events = <Map<String, Object>>[];
    upstream.listen((r) async {
      expect(r.headers.value('authorization'), 'Bearer supplier-fixture');
      received.add(await utf8.decoder.bind(r).join());
      if (stall) return;
      r.response.statusCode =
          statuses[(received.length - 1).clamp(0, statuses.length - 1)];
      if (stallRead) {
        r.response.contentLength = 100;
        r.response.write('{');
        await r.response.flush();
        return;
      }
      r.response.write(
        r.response.statusCode == 200
            ? '{"text":"hello"}'
            : 'supplier-private-response',
      );
      await r.response.close();
    });
    var factories = 0;
    final handler = VeniceRelay(
      key: 'supplier-fixture',
      token: 'phone-fixture',
      upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
      textBudget: Duration(milliseconds: stall || stallRead ? 100 : 5000),
      audioBudget: const Duration(seconds: 5),
      retryDelay: Duration.zero,
      onEvent: events.add,
      clientFactory: () {
        final c = HttpClient();
        if (failConnect && factories++ == 0) {
          c.connectionFactory = (_, _, _) =>
              Future.error(const SocketException('private-socket-details'));
        }
        return c;
      },
    );
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen(handler.handle);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.close(force: true);
      await upstream.close(force: true);
    });
    Future<HttpClientResponse> call(bool audio) async {
      final r = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/api/v1/${audio ? 'audio/transcriptions' : 'chat/completions'}',
        ),
      );
      r.headers.set('authorization', 'Bearer phone-fixture');
      final body = audio
          ? '--fixture\r\nContent-Disposition: form-data; name="model"\r\n\r\nstt-xai-v1\r\n--fixture--\r\n'
          : jsonEncode({
              'model': 'venice-uncensored-1-2',
              'max_tokens': 40,
              'messages': [
                {'role': 'user', 'content': 'private-fixture-message'},
              ],
            });
      r.headers.contentType = audio
          ? ContentType(
              'multipart',
              'form-data',
              parameters: {'boundary': 'fixture'},
            )
          : ContentType.json;
      r.contentLength = utf8.encode(body).length;
      r.write(body);
      return r.close();
    }

    return (
      relay: handler,
      call: call,
      received: received,
      events: events,
      disconnect: () => client.close(force: true),
    );
  }

  for (final audio in [false, true]) {
    for (final status in [502, 503, 504]) {
      test(
        'one transient $status recovers, exact payload preserved, audio=$audio',
        () async {
          final f = await fixture([status, 200]);
          final r = await f.call(audio);
          expect(r.statusCode, 200);
          expect(r.headers.value('x-aihaptics-relay-attempts'), '2');
          expect(await utf8.decoder.bind(r).join(), '{"text":"hello"}');
          expect(f.received.length, 2);
          expect(f.received[0], f.received[1]);
          expect(jsonEncode(f.events), isNot(contains('private')));
          expect(f.relay.active, 0);
        },
      );
    }
  }
  for (final status in [401, 402, 403, 404, 422, 429, 302]) {
    test('status $status is not retried or redirected', () async {
      final f = await fixture([status, 200]);
      final r = await f.call(false);
      expect(r.statusCode, status);
      expect(r.headers.value('x-aihaptics-relay-attempts'), '1');
      expect(
        await utf8.decoder.bind(r).join(),
        isNot(contains('supplier-private')),
      );
      expect(f.received.length, 1);
    });
  }
  test(
    'pre-upload connection failure retries without duplicate supplier request',
    () async {
      final f = await fixture([200], failConnect: true);
      final r = await f.call(false);
      expect(r.statusCode, 200);
      expect(r.headers.value('x-aihaptics-relay-attempts'), '2');
      await r.drain<void>();
      expect(f.received.length, 1);
      expect(jsonEncode(f.events), contains('retry_connect_socket'));
      expect(jsonEncode(f.events), isNot(contains('private-socket')));
    },
  );
  test(
    'persistent upstream failure is bounded and exposes safe stage',
    () async {
      final f = await fixture([502]);
      final r = await f.call(true);
      expect(r.statusCode, 502);
      expect(r.headers.value('x-aihaptics-relay-attempts'), '2');
      expect(r.headers.value('x-aihaptics-relay-stage'), 'upstream_response');
      expect(r.headers.value('x-aihaptics-relay-error'), 'upstream_http');
      await r.drain<void>();
      expect(f.received.length, 2);
    },
  );
  for (final reading in [false, true]) {
    test(
      'ambiguous timeout after upload is not replayed, reading=$reading',
      () async {
        final f = await fixture([200], stall: !reading, stallRead: reading);
        final r = await f.call(false);
        expect(r.statusCode, 504);
        expect(r.headers.value('x-aihaptics-relay-error'), 'timeout');
        expect(
          r.headers.value('x-aihaptics-relay-stage'),
          reading ? 'upstream_read' : 'upstream_response',
        );
        await r.drain<void>();
        expect(f.received.length, 1);
        expect(f.relay.active, 0);
      },
    );
  }
  test('retry also respects upstream request rate bound', () async {
    final f = await fixture([502, 200]);
    f.relay.starts.addAll(
      List.filled(VeniceRelay.maxStartsPerMinute - 1, DateTime.now()),
    );
    final r = await f.call(false);
    expect(r.statusCode, 502);
    expect(r.headers.value('x-aihaptics-relay-attempts'), '1');
    await r.drain<void>();
    expect(f.received.length, 1);
  });
  test('phone disconnect during upstream wait releases capacity without escaping handler', () async {
    final f = await fixture([200], stall: true);
    final pending = f.call(false);
    final checked = expectLater(pending, throwsA(isA<Exception>()));
    while (f.received.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    f.disconnect();
    await checked;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(f.relay.active, 0);
    expect(f.received.length, 1);
  });
}
