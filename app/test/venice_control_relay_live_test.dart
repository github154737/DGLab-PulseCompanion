import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/venice_control_reply.dart';
import 'package:haptics_lab/venice_route.dart';
import 'package:haptics_lab/venice_wave_session.dart';

void main() {
  test('LAN relay: neutral conversation holds and later commands still execute', () async {
    expect(VeniceRoute.isRelay, true);
    final session = VeniceWaveSession()..grant();
    addTearDown(session.dispose);
    final rows = <Map<String, dynamic>>[];
    final cases = [
      ('你好，今天过得怎么样？', 'hold'),
      ('今天工作有点累，陪我聊一会儿吧', 'hold'),
      ('给我讲个笑话', 'hold'),
      ('我喜欢你', 'hold'),
      ('A 通道强一点，B 不变', 'set'),
      ('我们聊聊电影吧', 'hold'),
      ('换一个波形，保持强度', 'set'),
      ('谢谢你陪我聊天', 'hold'),
      ('停止', 'stop'),
    ];
    try {
      for (final (text, expected) in cases) {
        final provider = ApiModelProvider(
          endpoint: VeniceRoute.base,
          model: 'venice-uncensored-1-2', apiKey: VeniceRoute.relayToken,
          mode: ApiReplyMode.chat, temperature: .2, maxTokens: 250,
          jsonObjectOnly: true,
          systemPromptOverride: '${VeniceWaveSession.plannerPrompt}\nLocal state: ${jsonEncode(session.snapshot())}',
        );
        final timer = Stopwatch()..start();
        final previous = session.snapshot();
        final reply = await provider.respond(text, '');
        final command = decodeControlReply(reply.text);
        final receipt = session.apply(command, session.epoch);
        rows.add({
          'fixture': text, 'expected': expected, 'actual': command['action'],
          'ms': timer.elapsedMilliseconds, 'active': session.active,
          'a': session.strength[0], 'b': session.strength[1],
          'selected_changed': previous['selected'] != session.selected,
          'rejected': receipt.startsWith('未执行'),
        });
        expect(command['action'], expected);
        expect(receipt.startsWith('未执行'), false);
        expect(session.active, expected != 'stop');
        if (expected == 'hold') {
          expect(session.strength, [previous['a'], previous['b']]);
          expect(session.selected, previous['selected']);
        } else if (text.startsWith('A 通道')) {
          expect(session.strength, [2, 0]);
        } else if (text.startsWith('换一个')) {
          expect(session.selected, isNot(previous['selected']));
          expect(session.strength, [2, 0]);
        }
      }
    } finally {
      final report = Platform.environment['VENICE_CONTROL_REPORT'];
      if (report != null) {
        await File(report).writeAsString(const JsonEncoder.withIndent('  ').convert({
          'path': 'app ApiModelProvider -> LAN HTTPS relay -> Venice',
          'requests_completed': rows.length, 'results': rows,
          'physical_output': false, 'phone_verified': false,
        }));
      }
    }
  }, skip: !const bool.fromEnvironment('VENICE_RELAY_CONTROL_LIVE'), timeout: const Timeout(Duration(minutes: 5)));
}
