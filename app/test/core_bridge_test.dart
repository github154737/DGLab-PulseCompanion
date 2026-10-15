import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/chat_context.dart';

void main() {
  late CoreBridge core;
  setUp(() {
    core = CoreBridge();
    core.call({'op': 'reset_simulation'});
  });
  tearDown(() {
    core.call({'op': 'stop'});
  });
  void authorize() {
    expect(core.call({'op': 'connect', 'device_id': 'sim_single'})['ok'], true);
    expect(
      core.call({'op': 'authorize', 'limit': 0.3, 'lease_ms': 30000})['ok'],
      true,
    );
  }

  test(
    'API tool proposal passes through Rust and returns its actual result',
    () async {
      authorize();
      core.call({'op': 'start_experience', 'preset_id': 'soft_pulse'});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var count = 0;
      server.listen((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        count++;
        if (count == 2) {
          final result = jsonDecode((body['messages'] as List).last['content']);
          expect(result['ok'], true);
          expect(result['gain_target'], 0.6);
        }
        req.response.write(
          jsonEncode({
            'choices': [
              {
                'finish_reason': count == 1 ? 'tool_calls' : 'stop',
                'message': count == 1
                    ? {
                        'content': null,
                        'tool_calls': [
                          {
                            'id': 'fixture',
                            'type': 'function',
                            'function': {
                              'name': 'set_gain',
                              'arguments': '{"gain":0.6}',
                            },
                          },
                        ],
                      }
                    : {'content': '收到，调整已生效。'},
              },
            ],
          }),
        );
        await req.response.close();
      });
      final provider = ApiModelProvider(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1'),
        model: 'fixture',
      );
      final ticket = core.call({'op': 'begin_ai'})['result']['ticket'];
      final reply = await provider.respond(
        '强一点',
        'sim_single',
        context: const ChatContext(playing: true, remainingMs: 30000),
      );
      final executed = core.call({
        'op': 'complete_ai',
        'ticket': ticket,
        'response': jsonEncode(reply.intent),
      });
      expect(executed['ok'], true);
      expect(executed['state']['gain_target'], 0.6);
      expect(executed['state']['continuous'], true);
      expect(
        await provider.finishToolCall(reply, {
          'ok': executed['ok'],
          'gain_target': executed['state']['gain_target'],
        }),
        contains('生效'),
      );
      expect(count, 2);
    },
  );

  test('Dart FFI reads and changes real Rust state', () {
    expect(core.call({'op': 'snapshot'})['state']['simulation_only'], true);
    authorize();
    expect(core.call({'op': 'snapshot'})['state']['phase'], 'authorized');
    expect(core.call({'op': 'stop'})['state']['phase'], 'stopped');
  });
  test('Fake model passes through the same native validation path', () async {
    authorize();
    final ticket = core.call({'op': 'begin_ai'})['result']['ticket'];
    final reply = await const FakeModelProvider(delay: Duration.zero)
        .respond('脉冲', 'sim_single');
    final result = core.call({
      'op': 'complete_ai',
      'ticket': ticket,
      'response': jsonEncode(reply.intent),
    });
    expect(result['ok'], true);
    expect(result['state']['phase'], 'playing');
  });
  test('native worker completes preset while Dart does not poll', () async {
    authorize();
    expect(
      core.call({
        'op': 'play',
        'preset_id': 'soft_pulse',
      })['state']['output'][0],
      greaterThan(0),
    );
    await Future<void>.delayed(const Duration(milliseconds: 2700));
    final state = core.call({'op': 'snapshot'})['state'];
    expect(state['phase'], 'authorized');
    expect(state['output'], [0.0, 0.0]);
    final events = state['events'] as List;
    final started =
        events.lastWhere(
              (e) => (e['message'] as String).contains('开始模拟预设'),
            )['at_ms']
            as int;
    final completed = events
        .where((e) => (e['message'] as String).contains('预设已完成'))
        .toList();
    expect(completed.length, 1);
    // A completion first triggered by the snapshot would be >= 2700 ms.
    expect(
      (completed.single['at_ms'] as int) - started,
      inInclusiveRange(2400, 2650),
    );
  });
  test('late fake model response cannot undo stop', () async {
    authorize();
    final ticket = core.call({'op': 'begin_ai'})['result']['ticket'];
    final pending = const FakeModelProvider(delay: Duration(milliseconds: 30))
        .respond('起伏', 'sim_single');
    core.call({'op': 'stop'});
    final reply = await pending;
    expect(
      core.call({
        'op': 'complete_ai',
        'ticket': ticket,
        'response': jsonEncode(reply.intent),
      })['ok'],
      false,
    );
    expect(core.call({'op': 'snapshot'})['state']['output'], [0.0, 0.0]);
  });
}
