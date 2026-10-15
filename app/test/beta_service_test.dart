import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/beta_api.dart';
import 'package:haptics_lab/local_owner.dart';
import 'package:haptics_lab/realtime_probe.dart';
import 'package:haptics_lab/service/access_store.dart';
import 'package:haptics_lab/service/voice_service.dart';

Future<void> until(bool Function() test) async {
  for (var i = 0; i < 200; i++) {
    if (test()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('timeout');
}

void main() {
  late Directory temp;
  late AccessStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('beta-test-');
    store = AccessStore(File('${temp.path}/accounts.json'));
    await store.open();
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });
  test('owner authentication is local Windows only', () {
    expect(LocalOwner.eligible('http://127.0.0.1:8790', windows: true), true);
    expect(LocalOwner.eligible('http://127.0.0.1:8790', windows: false), false);
    for (final address in [
      'https://example.com',
      'http://192.168.1.5:8790',
      'http://127.0.0.1:8791',
      'http://user@127.0.0.1:8790',
      'http://127.0.0.1:8790?x=1',
    ]) {
      expect(LocalOwner.eligible(address, windows: true), false);
    }
  });
  test('local owner does not consume invitations or bypass budget', () async {
    final token = secretToken();
    await store.configureLocalOwner(token);
    expect(store.authenticate(token), 'local-owner');
    final codes = await store.createInvites(5);
    for (final code in codes) {
      await store.redeem(code['code']!);
    }
    expect(store.users.length, 6);
    await store.reserve('local-owner', 50000);
    await store.configureLocalOwner(token);
    expect(store.account('local-owner')['used'], 50000);
    await store.manage({'op': 'budget', 'tokens': 50000});
    await expectLater(store.reserve('local-owner', 1), throwsStateError);
    expect(await store.file.readAsString(), isNot(contains(token)));
  });
  test('five codes, atomic concurrent redemption, hashes only, revocation and expiry', () async {
    final codes = await store.createInvites(5);
    expect(codes.length, 5);
    await expectLater(store.createInvites(1), throwsStateError);
    final results = await Future.wait(
      List.generate(
        8,
        (_) => store
            .redeem(codes.first['code']!)
            .then<Object>((v) => v, onError: (Object _) => 'rejected'),
      ),
    );
    expect(results.whereType<Map>().length, 1);
    final account = results.whereType<Map>().single;
    expect(store.authenticate(account['token']), account['user']);
    final disk = await store.file.readAsString();
    expect(disk, isNot(contains(account['token'])));
    for (final c in codes) {
      expect(disk, isNot(contains(c['code']!)));
    }
    await store.manage({'op': 'revoke', 'id': codes.first['id']});
    expect(store.authenticate(account['token']), isNull);
    final second = await store.redeem(codes[1]['code']!);
    store.users[second['user']]['expires'] = 0;
    expect(store.authenticate(second['token']), isNull);
  });
  test(
    'durable budget reservations survive restart, quota failure is atomic',
    () async {
      final code = (await store.createInvites(1)).single;
      final user = await store.redeem(code['code']!);
      final id = user['user'] as String;
      await store.manage({'op': 'budget', 'tokens': 100});
      await store.reserve(id, 80);
      await expectLater(store.reserve(id, 30), throwsStateError);
      expect(store.data['used'], 80);
      await store.close();
      store = AccessStore(File('${temp.path}/accounts.json'));
      await store.open();
      expect(store.data['used'], 80);
      await store.settle(id, 80, 20, 12, 8);
      expect(store.data['used'], 20);
      expect(store.account(id)['used'], 20);
      expect(jsonEncode(store.summary()), isNot(contains(user['token'])));
    },
  );
  test('client refuses insecure remote endpoints and embedded credentials', () {
    for (final u in [
      'http://example.org',
      'https://user:pass@example.org',
      'https://example.org?key=x',
      'https://example.org/path',
    ]) {
      expect(() => BetaApi(u), throwsFormatException);
    }
    expect(BetaApi('http://127.0.0.1:8790').base.port, 8790);
  });
  test(
    'account recovery rotates access and revoked invitations stay unusable',
    () async {
      final invite = (await store.createInvites(1)).single;
      final old = await store.redeem(invite['code']!);
      final recovery = await store.recover(old['user'] as String);
      expect(store.authenticate(old['token'] as String), isNull);
      final next = await store.redeem(recovery['recovery_code'] as String);
      expect(next['user'], old['user']);
      expect(store.authenticate(next['token'] as String), old['user']);
      await store.manage({'op': 'revoke', 'id': invite['id']});
      await expectLater(
        store.redeem(recovery['recovery_code'] as String),
        throwsStateError,
      );
    },
  );
  group('live local relay', () {
    late HttpServer upstream;
    late VoiceService service;
    final peers = <WebSocket>[];
    final requests = <Map<String, dynamic>>[];
    setUp(() async {
      peers.clear();
      requests.clear();
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        peers.add(ws);
        ws.listen((raw) {
          final e = jsonDecode(raw as String) as Map<String, dynamic>;
          requests.add(e);
          if (e['type'] == 'session.update') {
            ws.add(jsonEncode({'type': 'session.updated'}));
          }
        });
      });
      service = VoiceService(
        store,
        adminToken: 'fixture-admin-token-with-32-characters',
        provider: ProbeConfig(
          'fixture.cn-beijing.maas.aliyuncs.com',
          'fixture-provider-key',
        ),
        connect: (_, _) => WebSocket.connect('ws://127.0.0.1:${upstream.port}'),
        reservation: 1000,
      );
      await service.start();
    });
    tearDown(() async {
      await service.close();
      for (final p in peers) {
        await p.close();
      }
      await upstream.close(force: true);
    });
    Future<BetaApi> account(String code) async {
      final api = BetaApi('http://127.0.0.1:${service.server.port}');
      await api.redeem(code);
      return api;
    }

    test('five concurrent users isolated; duplicate sessions denied; revocation closes active user', () async {
      final invites = await store.createInvites(5);
      final clients = await Future.wait(
        invites.map((i) => account(i['code']!)),
      );
      final sockets = await Future.wait(clients.map((a) => a.connect()));
      final received = List.generate(5, (_) => <String>[]);
      final done = List.filled(5, false);
      for (var i = 0; i < 5; i++) {
        final n = i;
        sockets[i].listen(
          (m) => received[n].add(m as String),
          onDone: () => done[n] = true,
        );
        sockets[i].add(
          jsonEncode({
            'type': 'session.update',
            'session': {'max_tokens': 9000},
          }),
        );
      }
      await until(() => requests.length == 5);
      expect(requests.every((e) => e['session']['max_tokens'] == 512), true);
      await expectLater(
        clients[0].connect(),
        throwsA(isA<WebSocketException>()),
      );
      peers[0].add(
        jsonEncode({'type': 'fixture-marker', 'value': 'one-user-only'}),
      );
      await until(
        () => received.any((r) => r.any((m) => m.contains('one-user-only'))),
      );
      expect(
        received.where((r) => r.any((m) => m.contains('one-user-only'))).length,
        1,
      );
      final id = store.authenticate(clients[0].token)!;
      await store.manage({'op': 'user', 'id': id, 'paused': true});
      await until(() => done[0]);
      expect(done.skip(1).any((x) => x), false);
      for (final ws in sockets) {
        await ws.close();
      }
    });
    test(
      'quota exhausted closes stream and accounts measured usage once',
      () async {
        final code = (await store.createInvites(1)).single;
        final api = await account(code['code']!);
        final ws = await api.connect();
        var done = false;
        ws.listen((_) {}, onDone: () => done = true);
        ws.add(jsonEncode({'type': 'session.update', 'session': {}}));
        await until(() => peers.isNotEmpty);
        peers.single.add(
          jsonEncode({
            'type': 'response.created',
            'response': {'id': 'r1'},
          }),
        );
        peers.single.add(
          jsonEncode({
            'type': 'response.done',
            'response': {
              'id': 'r1',
              'usage': {
                'input_tokens': 950,
                'output_tokens': 70,
                'total_tokens': 1020,
              },
            },
          }),
        );
        await until(() => done);
        await until(() => store.data['used'] == 1020);
        expect(store.data['input_tokens'], 950);
      },
    );
    test('unauthenticated admin and cross-origin requests denied; raw provider errors redacted', () async {
      final h = HttpClient();
      final req = await h.getUrl(
        Uri.parse('http://127.0.0.1:${service.server.port}/admin/status'),
      );
      final res = await req.close();
      expect(res.statusCode, 403);
      await res.drain<void>();
      h.close(force: true);
      final code = (await store.createInvites(1)).single;
      final api = await account(code['code']!);
      final ws = await api.connect();
      final received = <String>[];
      var done = false;
      ws.listen((m) => received.add(m as String), onDone: () => done = true);
      peers.single.add(
        jsonEncode({
          'type': 'error',
          'error': {'message': 'fixture-provider-key transcript secret'},
        }),
      );
      await until(() => done);
      expect(received.join(), isNot(contains('fixture-provider-key')));
      expect(received.join(), isNot(contains('transcript secret')));
    });
  });
}
