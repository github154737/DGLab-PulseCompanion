import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/http_connection_pool.dart';

void main() {
  test(
    'consumed requests reuse the same TCP socket; credentials stay isolated',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final ports = <int>[];
      server.listen((request) async {
        ports.add(request.connectionInfo!.remotePort);
        await request.drain<void>();
        request.response.write('ok');
        await request.response.close();
      });
      final pool = HttpConnectionPool();
      addTearDown(() async {
        pool.invalidate();
        await server.close(force: true);
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}');
      Future<void> get(String key) async {
        final lease = pool.acquire(key, HttpClient.new);
        await lease.ready;
        final response = await (await lease.client.getUrl(uri)).close();
        await response.drain<void>();
        lease.release(reusable: true);
      }

      await get('account-one');
      await get('account-one');
      await get('account-two');
      expect(ports[0], ports[1]);
      expect(ports[2], isNot(ports[0]));
    },
  );

  test(
    'cancellation is exclusive and network change retires active leases',
    () async {
      final pool = HttpConnectionPool();
      addTearDown(pool.invalidate);
      final a = pool.acquire('origin', HttpClient.new);
      final b = pool.acquire('origin', HttpClient.new);
      expect(a.client, isNot(same(b.client)));
      a.release();
      b.release(reusable: true);
      final reused = pool.acquire('origin', HttpClient.new);
      expect(reused.client, same(b.client));
      pool.invalidate();
      reused.release(reusable: true);
      final fresh = pool.acquire('origin', HttpClient.new);
      expect(fresh.reused, isFalse);
      expect(fresh.client, isNot(same(b.client)));
      fresh.release();
    },
  );

  test(
    'idle expiry and unsuccessful responses never reuse closed clients',
    () async {
      final pool = HttpConnectionPool(
        idleTime: const Duration(milliseconds: 15),
      );
      addTearDown(pool.invalidate);
      final a = pool.acquire('origin', HttpClient.new);
      a.release(reusable: true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final b = pool.acquire('origin', HttpClient.new);
      expect(b.reused, isFalse);
      b.release();
      b.release(
        reusable: true,
      ); // double release cannot resurrect cancelled client
      final c = pool.acquire('origin', HttpClient.new);
      expect(c.reused, isFalse);
      c.release();
    },
  );
}
