import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/realtime_probe.dart';
import 'package:haptics_lab/realtime_probe_server.dart';

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('fixture_timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class Fixture {
  late HttpServer server;
  WebSocket? remote;
  final received = <Map<String, dynamic>>[];
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      remote = await WebSocketTransformer.upgrade(req);
      remote!.listen((raw) {
        final event = jsonDecode(raw as String) as Map<String, dynamic>;
        received.add(event);
        if (event['type'] == 'session.update') {
          send({'type': 'session.updated', 'session': event['session']});
        }
      });
    });
  }

  Future<WebSocket> connect(Uri _, String _) =>
      WebSocket.connect('ws://127.0.0.1:${server.port}');
  void send(Map<String, dynamic> event) => remote!.add(jsonEncode(event));
  Future<void> close() async {
    await remote?.close();
    await server.close(force: true);
  }
}

void main() {
  late CoreBridge core;
  late RealtimeProbe probe;
  late Fixture fixture;
  late List<Map<String, dynamic>> events;
  final config = ProbeConfig(
    'fixture.cn-beijing.maas.aliyuncs.com',
    'fixture-secret-only',
  );

  setUp(() async {
    core = CoreBridge();
    core.call({'op': 'reset_simulation'});
    fixture = Fixture();
    await fixture.start();
    events = [];
    probe = RealtimeProbe(core.call, events.add, connect: fixture.connect);
    await probe.start(config);
  });
  tearDown(() async {
    await probe.close();
    await fixture.close();
  });

  void begin(String id) {
    probe.handle({'type': 'input_audio_buffer.speech_started'});
    probe.handle({'type': 'input_audio_buffer.speech_stopped'});
    probe.handle({
      'type': 'response.created',
      'response': {'id': id},
    });
  }

  Map<String, dynamic> call(String id, String callId, String action) => {
    'type': 'response.function_call_arguments.done',
    'response_id': id,
    'call_id': callId,
    'name': 'simulation_control',
    'arguments': jsonEncode({'action': action}),
  };
  void done(String id, [String status = 'completed']) {
    probe.handle({
      'type': 'response.done',
      'response': {'id': id, 'status': status},
    });
  }

  test(
    'real WebSocket setup requests duplex PCM and nested Qwen tool schema',
    () async {
      expect(probe.ready, true);
      final session = fixture.received.single['session'];
      expect(session['input_audio_format'], 'pcm');
      expect(session['tools'][0]['function']['name'], 'simulation_control');
      probe.appendAudio([0, 0, 1, 0]);
      await until(() => fixture.received.length == 2);
      expect(fixture.received.last['audio'], base64Encode([0, 0, 1, 0]));
    },
  );

  test('provider host validation rejects credential exfiltration and endpoint mixing', () {
    for (final host in [
      'evil.example',
      'abc.cn-beijing.maas.aliyuncs.com.evil.example',
      'abc.cn-beijing.maas.aliyuncs.com/path',
      'https://user@abc.cn-beijing.maas.aliyuncs.com',
      'abc.ap-southeast-1.maas.aliyuncs.com',
      'abc.cn-beijing.maas.aliyuncs.com:444',
    ]) {
      expect(
        () => ProbeConfig(host, 'fixture-secret-only'),
        throwsFormatException,
      );
    }
    expect(config.uri.scheme, 'wss');
    expect(config.uri.queryParameters['model'], ProbeConfig.model);
  });

  test('completed tool changes real Rust simulator 50 to 60 percent with actual receipt', () async {
    expect(probe.grant()['ok'], true);
    begin('r1');
    probe.handle(call('r1', 'c1', 'increase'));
    expect(probe.state['gain_target'], 0.5); // arguments alone do not execute
    done('r1');
    expect(probe.state['gain_target'], closeTo(0.6, 1e-8));
    expect(probe.state['phase'], 'playing');
    await until(
      () =>
          fixture.received.any((e) => e['type'] == 'conversation.item.create'),
    );
    final receipt = fixture.received.firstWhere(
      (e) => e['type'] == 'conversation.item.create',
    );
    expect(
      jsonDecode(receipt['item']['output'])['gain_target'],
      closeTo(0.6, 1e-8),
    );
    expect(events.where((e) => e['type'] == 'receipt').single['ok'], true);
  });

  test('speech interruption rejects delayed audio and tool execution', () {
    probe.grant();
    begin('old');
    probe.handle(call('old', 'late', 'increase'));
    probe.handle({'type': 'input_audio_buffer.speech_started'});
    probe.handle({
      'type': 'response.audio.delta',
      'response_id': 'old',
      'delta': 'AAAA',
    });
    done('old');
    expect(probe.state['gain_target'], 0.5);
    expect(events.where((e) => e['type'] == 'audio'), isEmpty);
    expect(core.call({'op': 'snapshot'})['state']['pending_ai'], 0);
  });

  test('local stop and reauthorization cannot revive an old response', () {
    probe.grant();
    begin('old');
    probe.stopOutput();
    probe.grant();
    probe.handle(call('old', 'late', 'increase'));
    done('old');
    expect(probe.state['gain_target'], 0.5);
    probe.stopOutput();
    expect(probe.state['phase'], 'stopped');
    expect(probe.state['output'], [0.0, 0.0]);
  });

  test('partial arguments, cancelled response, duplicate response do not execute twice', () {
    probe.grant();
    begin('r');
    probe.handle({
      'type': 'response.function_call_arguments.delta',
      'response_id': 'r',
      'delta': '{"action":"increase"}',
    });
    done('r');
    expect(probe.state['gain_target'], 0.5);
    begin('cancelled');
    probe.handle(call('cancelled', 'c', 'increase'));
    done('cancelled', 'cancelled');
    expect(probe.state['gain_target'], 0.5);
    begin('one');
    final event = call('one', 'once', 'increase');
    probe.handle(event);
    probe.handle(event);
    done('one');
    done('one');
    expect(probe.counts['accepted_tools'], 1);
  });

  test('multiple actions are rejected together without partial execution', () {
    probe.grant();
    begin('multi');
    probe.handle(call('multi', 'a', 'increase'));
    probe.handle(call('multi', 'b', 'decrease'));
    done('multi');
    expect(probe.state['gain_target'], 0.5);
    expect(probe.counts['rejected_tools'], 2);
  });

  test(
    'unauthorized action rejected but next spoken explanation is allowed',
    () {
      begin('chat');
      probe.handle(call('chat', 'c', 'increase'));
      done('chat');
      expect(probe.counts['accepted_tools'], isNull);
      expect(probe.counts['rejected_tools'], 1);
      probe.handle({
        'type': 'response.created',
        'response': {'id': 'explain'},
      });
      probe.handle({
        'type': 'response.audio.delta',
        'response_id': 'explain',
        'delta': 'AAAA',
      });
      expect(events.where((e) => e['type'] == 'audio'), hasLength(1));
    },
  );

  test('followup never gets a fresh ticket for chained increases', () {
    probe.grant();
    begin('r');
    probe.handle(call('r', 'c', 'increase'));
    done('r');
    probe.handle({
      'type': 'response.created',
      'response': {'id': 'followup'},
    });
    probe.handle(call('followup', 'chain', 'increase'));
    done('followup');
    expect(probe.state['gain_target'], closeTo(0.6, 1e-8));
    expect(probe.counts['rejected_tools'], 1);
    expect(core.call({'op': 'snapshot'})['state']['pending_ai'], 0);
  });

  test(
    'decrease and stop use native core, invalid arguments cannot mutate it',
    () {
      probe.grant();
      begin('down');
      probe.handle(call('down', 'd', 'decrease'));
      done('down');
      expect(probe.state['gain_target'], closeTo(0.4, 1e-8));
      begin('bad');
      probe.handle({
        ...call('bad', 'b', 'increase'),
        'arguments': '{"action":"increase","limit":1}',
      });
      done('bad');
      expect(probe.state['gain_target'], closeTo(0.4, 1e-8));
      begin('stop');
      probe.handle(call('stop', 's', 'stop'));
      done('stop');
      expect(probe.state['phase'], 'stopped');
      expect(probe.state['output'], [0.0, 0.0]);
      final receipt = events.lastWhere((e) => e['type'] == 'receipt');
      expect(receipt['output'], [0.0, 0.0]);
      expect(receipt['gain_target'], probe.state['gain_target']);
    },
  );

  test('expired native lease rejects an in-flight model action', () async {
    core.call({'op': 'connect', 'device_id': 'sim_single'});
    core.call({'op': 'authorize', 'limit': 0.3, 'lease_ms': 2500});
    begin('expired');
    probe.handle(call('expired', 'c', 'increase'));
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    done('expired');
    expect(probe.counts['accepted_tools'], isNull);
    expect(probe.state['output'], [0.0, 0.0]);
  });

  test(
    'upstream disconnect stops native output and clears live readiness',
    () async {
      probe.grant();
      await fixture.remote!.close();
      await until(() => !probe.ready);
      expect(probe.state['phase'], 'stopped');
      expect(probe.state['output'], [0.0, 0.0]);
    },
  );

  test(
    'sanitized report and error do not expose transcript, PCM or credentials',
    () {
      begin('r');
      probe.handle({
        'type': 'conversation.item.input_audio_transcription.completed',
        'transcript': 'private-transcript',
      });
      probe.handle({
        'type': 'response.audio.delta',
        'response_id': 'r',
        'delta': 'private-audio',
      });
      probe.handle({
        'type': 'error',
        'error': {'message': 'fixture-secret-only private-error'},
      });
      final report = jsonEncode(probe.report());
      for (final secret in [
        'private-transcript',
        'private-audio',
        'private-error',
        'fixture-secret-only',
        'fixture.cn-beijing',
      ]) {
        expect(report, isNot(contains(secret)));
        expect(
          jsonEncode(events.where((e) => e['type'] == 'closed').toList()),
          isNot(contains(secret)),
        );
      }
    },
  );

  test(
    'background pause preserves voice connection but revokes pending output',
    () {
      probe.grant();
      begin('r');
      probe.handle(call('r', 'c', 'increase'));
      probe.pause();
      done('r');
      expect(probe.ready, true);
      expect(probe.state['phase'], 'stopped');
      expect(probe.state['output'], [0.0, 0.0]);
      expect(probe.counts['accepted_tools'], isNull);
      expect(probe.report()['lifecycle'].last['event'], 'capture_paused');
    },
  );

  test('style is sent upstream alongside invariant action restrictions', () {
    final instructions =
        fixture.received.first['session']['instructions'] as String;
    expect(instructions, contains('俏皮'));
    expect(instructions, contains('不能授权、续期或连接实物'));
    expect(instructions, contains('收到工具回执'));
    expect(
      () => ProbeConfig(config.uri.host, config.key, style: 'unknown'),
      throwsFormatException,
    );
  });

  test('only a correlated harmless cancel race is ignored', () async {
    begin('r');
    probe.interrupt();
    await until(
      () => fixture.received.any((e) => e['type'] == 'response.cancel'),
    );
    final id = fixture.received.lastWhere(
      (e) => e['type'] == 'response.cancel',
    )['event_id'];
    probe.handle({
      'type': 'error',
      'error': {'event_id': id, 'message': 'No active response to cancel'},
    });
    expect(probe.ready, true);
    expect(probe.counts['cancel_race_ignored'], 1);
    probe.handle({
      'type': 'error',
      'error': {
        'event_id': 'unrelated',
        'message': 'No active response to cancel',
      },
    });
    expect(probe.ready, false);
    expect(
      probe.report()['lifecycle'].last['event'],
      'provider_or_session_error',
    );
  });

  test('server retains credentials for explicit reconnect, forget and TTL clear them', () async {
    final temp = await Directory.systemTemp.createTemp('voice-cache-test-');
    final service = ProbeServer(
      core.call,
      Directory('tool/voice_probe'),
      File('${temp.path}/report.json'),
      connector: fixture.connect,
      credentialLifetime: const Duration(seconds: 2),
    );
    await service.start();
    final client = HttpClient();
    final browser = await WebSocket.connect(
      'ws://127.0.0.1:${service.server.port}/ws?token=${service.token}',
      headers: {'Origin': service.origin},
    );
    final browserEvents = <String>[];
    browser.listen((event) => browserEvents.add(event as String));
    Future<Map<String, dynamic>> post(
      String path, [
      Map<String, dynamic> body = const {},
    ]) async {
      final req = await client.postUrl(Uri.parse('${service.origin}$path'));
      req.headers.set('origin', service.origin);
      req.headers.set('x-probe-token', service.token);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final result = await req.close();
      return jsonDecode(await utf8.decoder.bind(result).join())
          as Map<String, dynamic>;
    }

    try {
      expect(
        (await post('/connect', {
          'host': config.uri.host,
          'key': config.key,
        }))['ok'],
        true,
      );
      expect(service.hasCredentials, true);
      await post('/disconnect', {'reason': 'audio_backpressure'});
      expect(service.hasCredentials, true);
      expect(service.probe.ready, false);
      await service.saveReport();
      final saved = await service.reportFile.readAsString();
      expect(saved, contains('audio_backpressure'));
      expect(saved, isNot(contains(config.key)));
      expect(
        (await post('/connect', {'key': '', 'style': 'gentle'}))['ok'],
        true,
      );
      expect(service.probe.style, 'gentle');
      expect(jsonEncode(browserEvents), isNot(contains(config.key)));
      await post('/forget');
      expect(service.hasCredentials, false);
      expect((await post('/connect'))['error'], contains('已清除或过期'));
      expect(
        (await post('/connect', {
          'host': config.uri.host,
          'key': config.key,
        }))['ok'],
        true,
      );
      await until(() => !service.hasCredentials);
      expect(
        service.probe.ready,
        true,
      ); // Cache expiry does not falsely disconnect an authenticated session.
    } finally {
      await browser.close();
      client.close(force: true);
      await service.close();
      await temp.delete(recursive: true);
    }
  });

  test('loopback server enforces origin, token, no-store and contains no hardware route', () async {
    final temp = await Directory.systemTemp.createTemp('voice-probe-test-');
    final service = ProbeServer(
      core.call,
      Directory('tool/voice_probe'),
      File('${temp.path}/report.json'),
      connector: fixture.connect,
    );
    await service.start();
    final client = HttpClient();
    try {
      final get = await client.getUrl(Uri.parse('${service.origin}/'));
      final page = await get.close();
      expect(page.statusCode, 200);
      expect(page.headers.value('cache-control'), 'no-store');
      expect(await utf8.decoder.bind(page).join(), contains('实时语音验证'));
      for (final correctOrigin in [false, true]) {
        final req = await client.postUrl(Uri.parse('${service.origin}/grant'));
        req.headers.set(
          'origin',
          correctOrigin ? service.origin : 'https://evil.example',
        );
        if (!correctOrigin) req.headers.set('x-probe-token', service.token);
        final response = await req.close();
        expect(response.statusCode, 403);
        await response.drain<void>();
      }
      await expectLater(
        WebSocket.connect(
          'ws://127.0.0.1:${service.server.port}/ws?token=${service.token}',
          headers: {'Origin': 'https://evil.example'},
        ),
        throwsA(isA<WebSocketException>()),
      );
      final req = await client.postUrl(Uri.parse('${service.origin}/report'));
      req.headers.set('origin', service.origin);
      req.headers.set('x-probe-token', service.token);
      final response = await req.close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      expect(
        jsonDecode(
          await service.reportFile.readAsString(),
        )['physical_device_verified'],
        false,
      );
      final bad = await client.getUrl(Uri.parse('${service.origin}/physical'));
      final missing = await bad.close();
      expect(missing.statusCode, 404);
      await missing.drain<void>();
    } finally {
      client.close(force: true);
      await service.close();
      await temp.delete(recursive: true);
    }
  });
}
