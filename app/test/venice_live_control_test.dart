import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/venice_wave_session.dart';

void main() {
  test('live neutral planner emits applicable structured commands', () async {
    final file = File(Platform.environment['VENICE_LOCAL_KEY_FILE']!);
    final key = RegExp(r'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}')
        .firstMatch(await file.readAsString())!
        .group(0)!;
    final s = VeniceWaveSession();
    addTearDown(s.dispose);
    s.grant();
    final results = <Map<String, dynamic>>[];
    for (final message in ['A 通道强一点，B 不变', '选用内置间歇脉冲，保持当前强度']) {
      final provider = ApiModelProvider(
        endpoint: Uri.parse('https://api.venice.ai/api/v1'),
        model: 'venice-uncensored-1-2',
        apiKey: key,
        mode: ApiReplyMode.chat,
        temperature: .2,
        maxTokens: 250,
        systemPromptOverride:
            '${VeniceWaveSession.plannerPrompt}\nLocal state: ${jsonEncode(s.snapshot())}',
      );
      final response = await provider.respond(message, '');
      final receipt = s.apply(jsonDecode(response.text), s.epoch);
      expect(receipt.startsWith('模拟已执行'), true);
      results.add({
        'a': s.strength[0],
        'b': s.strength[1],
        'selected': s.selected,
      });
    }
    expect(s.strength, [2, 0]);
    expect(s.selected, s.waves[1].id);
    await File(Platform.environment['VENICE_CONTROL_REPORT']!).writeAsString(
      jsonEncode({
        'requests': 2,
        'passed': true,
        'results': results,
        'physical_output': false,
      }),
    );
  }, skip: !const bool.fromEnvironment('VENICE_LIVE_CONTROL_TEST'));
}
