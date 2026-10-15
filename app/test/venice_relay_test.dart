import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/venice_relay.dart';

void main() {
  test(
    'relay reuses downstream and upstream sockets and correlates sanitized IDs',
    () async {
      final upstream = await HttpServer.bind('127.0.0.1', 0);
      final ports = <int>[];
      upstream.listen((r) async {
        ports.add(r.connectionInfo!.remotePort);
        await r.drain<void>();
        r.response.write('{"ok":true}');
        await r.response.close();
      });
      final events = <Map<String, Object>>[];
      final relay = VeniceRelay(
        key: 'supplier',
        token: 'phone',
        upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
        onEvent: events.add,
      );
      final server = await HttpServer.bind('127.0.0.1', 0);
      final phonePorts = <int>[];
      server.listen((r) {
        phonePorts.add(r.connectionInfo!.remotePort);
        relay.handle(r);
      });
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        relay.dispose();
        await server.close(force: true);
        await upstream.close(force: true);
      });
      for (final id in ['test-1', 'test-2', 'do not log this']) {
        final r = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/v1/models'),
        );
        r.headers.set('authorization', 'Bearer phone');
        r.headers.set('x-aihaptics-request-id', id);
        final response = await r.close();
        expect(response.statusCode, 200);
        expect(
          response.headers.value('x-aihaptics-request-id'),
          id.contains(' ') ? 'untracked' : id,
        );
        await response.drain<void>();
        await Future<void>.delayed(Duration.zero);
      }
      expect(ports.toSet(), hasLength(1));
      expect(phonePorts.toSet(), hasLength(1));
      expect(events.map((e) => e['request_id']), [
        'test-1',
        'test-2',
        'untracked',
      ]);
    },
  );

  test('relay authenticates, allowlists routes, preserves payload and replaces bearer', () async {
    final upstream = await HttpServer.bind('127.0.0.1', 0);
    final received = <String>[];
    upstream.listen((r) async {
      expect(r.headers.value('authorization'), 'Bearer supplier-fixture');
      received.add(await utf8.decoder.bind(r).join());
      r.response.headers.contentType = ContentType.json;
      r.response.write('{"ok":true}');
      await r.response.close();
    });
    final handler = VeniceRelay(
      key: 'supplier-fixture',
      token: 'phone-fixture',
      upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
    );
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen(handler.handle);
    final client = HttpClient();
    Future<int> call(
      String path, {
      String token = 'phone-fixture',
      String? body,
    }) async {
      final r = await client.openUrl(
        body == null ? 'GET' : 'POST',
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      r.headers.set('authorization', 'Bearer $token');
      if (body != null) {
        r.contentLength = utf8.encode(body).length;
        r.headers.contentType = ContentType.json;
        r.write(body);
      }
      final response = await r.close();
      await response.drain<void>();
      return response.statusCode;
    }

    try {
      expect(await call('/api/v1/models', token: 'wrong'), 401);
      expect(await call('/api/v1/anything'), 404);
      expect(await call('/api/v1/models?target=other'), 404);
      final body = jsonEncode({
        'model': 'venice-uncensored-1-2',
        'max_tokens': 40,
        'messages': [
          {'role': 'system', 'content': 'Unchanged fixture.'},
          {'role': 'user', 'content': 'Hello'},
        ],
        'stream': false,
      });
      expect(await call('/api/v1/chat/completions', body: body), 200);
      expect(received.single, body);
      final controlBody = body.replaceFirst(
        'venice-uncensored-1-2', 'z-ai-glm-5-3-flash',
      );
      expect(await call('/api/v1/chat/completions', body: controlBody), 200);
      expect(received.last, controlBody);
      expect(
        await call(
          '/api/v1/chat/completions',
          body: body.replaceFirst('venice-uncensored-1-2', 'another-model'),
        ),
        422,
      );
      expect(await call('/api/v1/chat/completions', body: 'x' * 140000), 413);
      handler.active = 2;
      expect(await call('/api/v1/models'), 429);
      expect(received.length, 2);
    } finally {
      client.close(force: true);
      await server.close(force: true);
      await upstream.close(force: true);
    }
  });
}
