import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/network_diagnostics.dart';
import 'package:haptics_lab/venice_control_reply.dart';
import 'package:haptics_lab/venice_wave_session.dart';

void main() {
  test('reject prose, fences, partial JSON and malformed commands without guessing', () {
    for (final content in [
      '你好，今天过得怎么样？',
      '```json\n{"action":"hold"}\n```',
      '{"action":',
      '[]',
      '{"action":"set","a":2,"b":2}',
      '{"action":"stop","reason":"extra"}',
      '{"action":"set","a":"2","b":2,"waveform_id":"x"}',
    ]) {
      expect(() => decodeControlReply(content), throwsA(isA<ControlReplyFailure>()));
    }
    expect(decodeControlReply('{"action":"hold"}'), {'action': 'hold'});
    expect(decodeControlReply('{"action":"stop"}'), {'action': 'stop'});
  });

  for (final physical in [false, true]) {
    test('control failure preserves simulation, stops physical: $physical', () {
      final session = VeniceWaveSession()..grant(toDevice: physical);
      addTearDown(session.dispose);
      final ticket = session.epoch;
      session.apply({'action': 'set', 'a': 2, 'b': 4, 'waveform_id': session.selected}, ticket);
      final selected = session.selected, started = session.started;
      final receipt = session.controlFailed('控制请求超时', ticket);
      expect(session.active, !physical);
      expect(session.strength, physical ? [0, 0] : [2, 4]);
      expect(receipt, contains(physical ? '安全停止' : '模拟保持'));
      expect(session.epoch, physical ? ticket + 1 : ticket);
      expect(session.selected, selected);
      expect(session.started, started);
      expect(session.physicalState()['phase'], 'stopped');
    });
  }

  test('late failures cannot revoke a new grant or resurrect stopped simulation', () {
    final session = VeniceWaveSession()..grant();
    addTearDown(session.dispose);
    final old = session.epoch;
    session.stop();
    session.controlFailed('控制请求超时', old);
    expect(session.active, false);
    session.grant(toDevice: true);
    final receipt = session.receipt, ticket = session.epoch;
    session.controlFailed('控制请求超时', old);
    expect(session.active, true);
    expect(session.epoch, ticket);
    expect(session.receipt, receipt);
  });

  test('hold preserves running state; explicit stop and limits still enforced', () {
    final session = VeniceWaveSession()..grant();
    addTearDown(session.dispose);
    session.apply({'action': 'set', 'a': 2, 'b': 2, 'waveform_id': session.selected}, session.epoch);
    session.apply(decodeControlReply('{"action":"hold"}'), session.epoch);
    expect(session.active, true);
    expect(session.strength, [2, 2]);
    expect(session.apply({'action': 'set', 'a': 20, 'b': 20, 'waveform_id': session.selected}, session.epoch), contains('单步'));
    expect(session.strength, [2, 2]);
    session.apply(decodeControlReply('{"action":"stop"}'), session.epoch);
    expect(session.active, false);
    expect(session.strength, [0, 0]);
  });

  test('diagnostics distinguish failures without exposing exception contents', () {
    final errors = <Object>[
      const ModelServiceException('SECRET', code: 'http_429'),
      TimeoutException('SECRET'),
      const ModelServiceException('SECRET', code: 'truncated'),
      const ModelServiceException('SECRET', code: 'network'),
      StateError('SECRET'),
    ];
    expect(errors.map((e) => ControlReplyFailure.from(e).code), ['http_429', 'timeout', 'truncated', 'network', 'unexpected']);
    for (final error in errors) {
      expect(ControlReplyFailure.from(error).label, isNot(contains('SECRET')));
    }
  });

  test('planner requests JSON; ordinary chat unchanged; truncated plans rejected', () async {
    final requests = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      requests.add(jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>);
      req.response.write(jsonEncode({'choices': [{
        'finish_reason': requests.length == 3 ? 'length' : 'stop',
        'message': {'content': '{"action":"hold"}'},
      }]}));
      await req.response.close();
    });
    ApiModelProvider provider(bool json) => ApiModelProvider(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1'),
      model: 'fixture', mode: ApiReplyMode.chat,
      jsonObjectOnly: json, systemPromptOverride: VeniceWaveSession.plannerPrompt,
    );
    final planned = await provider(true).respond('你好', '');
    expect(decodeControlReply(planned.text), {'action': 'hold'});
    await provider(false).respond('你好', '');
    await expectLater(provider(true).respond('你好', ''), throwsA(isA<ModelServiceException>().having((e) => e.code, 'code', 'truncated')));
    expect(requests[0]['response_format'], {'type': 'json_object'});
    expect(requests[0]['messages'][0]['content'], VeniceWaveSession.plannerPrompt);
    expect(requests[1].containsKey('response_format'), false);
    expect(NetworkTrace.report, contains('控制接口'));
  });
}
