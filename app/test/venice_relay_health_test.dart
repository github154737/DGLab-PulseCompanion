import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/venice_relay.dart';

void main() {
  test(
    'readiness requires authentication, stays local and consumes no quota',
    () async {
      var upstreamCalls = 0;
      final upstream = await HttpServer.bind('127.0.0.1', 0);
      upstream.listen((request) async {
        upstreamCalls++;
        request.response.write('{"data":[]}');
        await request.response.close();
      });
      final relay = VeniceRelay(
        key: 'supplier-fixture',
        token: 'phone-fixture',
        upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
      );
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen(relay.handle);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close(force: true);
        await upstream.close(force: true);
      });
      Future<({int status, String body})> call({
        String path = '/api/v1/health',
        String method = 'GET',
        bool authenticated = true,
      }) async {
        final request = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:${server.port}$path'),
        );
        if (authenticated) {
          request.headers.set('Authorization', 'Bearer phone-fixture');
        }
        final response = await request.close();
        return (
          status: response.statusCode,
          body: await utf8.decoder.bind(response).join(),
        );
      }

      expect((await call(authenticated: false)).status, 401);
      expect((await call(method: 'POST')).status, 404);
      expect((await call(path: '/api/v1/health?probe=1')).status, 404);
      for (var i = 0; i < 70; i++) {
        final response = await call();
        expect(response.status, 200);
        expect(jsonDecode(response.body), {'ready': true, 'version': '0.12.3'});
      }
      expect(upstreamCalls, 0);
      expect((await call(path: '/api/v1/models')).status, 200);
      expect(upstreamCalls, 1);
    },
  );
}
