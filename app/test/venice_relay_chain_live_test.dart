import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/network_diagnostics.dart';
import 'package:haptics_lab/venice_control_reply.dart';
import 'package:haptics_lab/venice_route.dart';
import 'package:haptics_lab/venice_transcription.dart';
import 'package:haptics_lab/venice_wave_session.dart';

void main() {
  test(
    'configured relay: repeated STT, control and text including maximum recording',
    () async {
      expect(VeniceRoute.isRelay, true);
      final session = VeniceWaveSession()..grant();
      addTearDown(session.dispose);
      final rows = <Map<String, Object>>[];
      final root = Platform.environment['VENICE_PROBE_REPORTS']!;
      final files = [
        'relay-test-speech.wav',
        'relay-test-speech-15s.wav',
        'relay-test-speech-60s.wav',
      ];
      try {
        for (var round = 0; round < files.length; round++) {
          final wav = await File('$root/${files[round]}').readAsBytes();
          var clock = Stopwatch()..start();
          final text = await VeniceTranscriber(apiKey: VeniceRoute.relayToken)
              .transcribe(wav);
          rows.add({
            'round': round,
            'stage': 'stt',
            'bytes': wav.length,
            'ms': clock.elapsedMilliseconds,
            'recognized': text.toLowerCase().contains('hello'),
          });
          expect(text.toLowerCase(), contains('hello'));
          final controller = ApiModelProvider(
            endpoint: VeniceRoute.base,
            model: veniceTextModel,
            apiKey: VeniceRoute.relayToken,
            mode: ApiReplyMode.chat,
            jsonObjectOnly: true,
            temperature: .2,
            maxTokens: 250,
            systemPromptOverride:
                '${VeniceWaveSession.plannerPrompt}\nLocal state: ${jsonEncode(session.snapshot())}',
          );
          clock = Stopwatch()..start();
          final planned = await controller.respond(
            round == 1 ? 'A 通道强一点，B 不变' : text,
            '',
          );
          final command = decodeControlReply(planned.text);
          final receipt = session.apply(command, session.epoch);
          expect(command['action'], round == 1 ? 'set' : 'hold');
          expect(session.active, true);
          expect(receipt.startsWith('未执行'), false);
          rows.add({
            'round': round,
            'stage': 'control',
            'ms': clock.elapsedMilliseconds,
            'a': session.strength[0],
            'action': command['action'] as String,
          });
          clock = Stopwatch()..start();
          // Neutral fixture isolates transport testing from the user's persona.
          final chat = ApiModelProvider(
            endpoint: VeniceRoute.base,
            model: veniceTextModel,
            apiKey: VeniceRoute.relayToken,
            mode: ApiReplyMode.chat,
            maxTokens: 60,
            systemPromptOverride: 'Reply to the user briefly in Chinese. This is a neutral connection test.',
          );
          final response = await chat.respond(text, '');
          expect(response.text.trim(), isNotEmpty);
          rows.add({
            'round': round,
            'stage': 'text',
            'ms': clock.elapsedMilliseconds,
            'characters': response.text.length,
          });
        }
        expect(NetworkTrace.report, contains('中继版本 0.12.0'));
      } finally {
        await File('$root/venice-relay-chain-live-0.12.0.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'rows': rows,
            'completed': rows.length == 9,
            'phone_verified': false,
            'physical_device_verified': false,
          }),
        );
      }
    },
    skip: !const bool.fromEnvironment('VENICE_CHAIN_LIVE'),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
