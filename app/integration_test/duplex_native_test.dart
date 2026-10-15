// Local-only Android integration check; no API, credentials or hardware output.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:haptics_lab/venice_recorder.dart';
import 'package:haptics_lab/venice_transcription.dart';
import 'package:haptics_lab/voice_audio.dart';
import 'package:haptics_lab/speech_audio_player.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native echo capability, recording/playback coexistence and cleanup',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('本地音频并发测试，不上传录音'))),
      );
      const channel = MethodChannel('aihaptics/speech');
      final capabilities = await channel.invokeMapMethod<String, dynamic>(
        'duplexCapture',
      );
      await channel.invokeMethod<void>('endDuplexCapture');
      final capture = NativeSpeechCapture()..duplex = true;
      final player = NativeSpeechAudioPlayer();
      final events = <SpeechPlaybackEvent>[];
      final eventSub = player.events.listen(events.add);
      StreamSubscription<Uint8List>? samples;
      var bytes = 0;
      try {
        if (capabilities?['supported'] == true) {
          samples = (await capture.start()).listen(
            (part) => bytes += part.length,
          );
          await player.play(pcmToWav(Uint8List(32000 * 3)));
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(bytes, greaterThan(0));
          expect(
            events.any((e) => e.state == SpeechPlaybackState.playing),
            true,
          );
          expect(
            events.any(
              (e) =>
                  e.state == SpeechPlaybackState.error ||
                  e.state == SpeechPlaybackState.stopped,
            ),
            false,
          );
          debugPrint(
            'DUPLEX_NATIVE coexistence passed; acoustic echo quality NOT tested',
          );
        } else {
          await expectLater(
            capture.start(),
            throwsA(
              isA<VoiceAudioFailure>().having(
                (e) => e.code,
                'code',
                'echo_unavailable',
              ),
            ),
          );
          debugPrint(
            'DUPLEX_NATIVE unsupported AEC correctly blocked; acoustic test unavailable',
          );
        }
        await player.stop();
        await samples?.cancel();
        samples = null;
        await capture.stop();
        // Both unsupported and successful paths must leave a usable microphone.
        capture.duplex = false;
        bytes = 0;
        samples = (await capture.start()).listen(
          (part) => bytes += part.length,
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(bytes, greaterThan(0));
        debugPrint(
          'DUPLEX_NATIVE microphone restart passed; no audio saved or uploaded',
        );
      } finally {
        await player.stop();
        await samples?.cancel();
        await capture.stop();
        await eventSub.cancel();
        await player.dispose();
      }
    },
  );
}
