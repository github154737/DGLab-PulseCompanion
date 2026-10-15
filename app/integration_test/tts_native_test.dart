// Opt-in paid Android smoke test: exactly one neutral TTS request through the
// configured relay. No microphone, chat API, Bluetooth or device commands.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:haptics_lab/background_session.dart';
import 'package:haptics_lab/speech_audio_player.dart';
import 'package:haptics_lab/speech_output.dart';
import 'package:haptics_lab/speech_widgets.dart';
import 'package:haptics_lab/venice_route.dart';
import 'package:haptics_lab/venice_tts.dart';
import 'package:haptics_lab/warm_theme.dart';

const _sample = '你好，这是手机语音输出测试。现在可以听到中文女声。点击停止，或者开始录音，都应该立即结束朗读。';

class _ObservedClient extends VeniceTtsClient {
  _ObservedClient(this.onAudio) : super(apiKey: VeniceRoute.relayToken);
  final void Function(Uint8List) onAudio;

  @override
  Future<Uint8List> synthesize(
    String text, {
    String voice = 'eve',
    double speed = 1,
  }) async {
    final audio = await super.synthesize(text, voice: voice, speed: speed);
    onAudio(audio);
    return audio;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'relay Eve MP3 -> Android progress/completion -> replay/stop -> cancel prepare',
    (tester) async {
      expect(
        Platform.isAndroid,
        true,
        reason: 'Run this smoke test on Android.',
      );
      expect(VeniceRoute.isRelay, true, reason: 'A relay build is required.');
      expect(VeniceRoute.relayToken.isNotEmpty, true);
      final background = BackgroundSession();
      final player = NativeSpeechAudioPlayer();
      final events = <SpeechPlaybackEvent>[];
      final subscription = player.events.listen(events.add);
      final messageId = Object();
      Uint8List? generated;
      var requests = 0;
      var foregroundStarted = false;
      final output = SpeechOutput(
        createClient: () {
          requests++;
          // Fail instead of silently paying again if the replay cache regresses.
          if (requests != 1) {
            throw StateError('Unexpected additional TTS request');
          }
          return _ObservedClient((bytes) => generated = bytes);
        },
        player: player,
        preparePlayback: () async {
          final ok = await background.update(active: true, mediaPlayback: true);
          foregroundStarted = foregroundStarted || ok;
          return ok;
        },
      );
      background.onStop = () => unawaited(output.stop());
      final report = <String, Object?>{
        'ok': false,
        'voice': 'eve',
        'language': 'zh',
        'chat_requests': 0,
        'microphone_used': false,
        'device_commands': 0,
        'platform': 'android',
      };
      final cache = await getTemporaryDirectory();
      const screenshots = bool.fromEnvironment(
        'VENICE_TTS_SCREENSHOTS',
        defaultValue: true,
      );
      final previewKey = GlobalKey();

      Future<void> waitFor(bool Function() ready, {int seconds = 80}) async {
        final clock = Stopwatch()..start();
        while (!ready()) {
          if (output.phase == SpeechOutputPhase.failed) {
            fail('TTS smoke test failed: ${output.error}');
          }
          if (clock.elapsed > Duration(seconds: seconds)) {
            fail('TTS native state timed out.');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> capture(String name) async {
        if (!screenshots) return;
        await tester.pump();
        final boundary =
            previewKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${cache.path}/$name.png')
            .writeAsBytes(data!.buffer.asUint8List(), flush: true);
        image.dispose();
        // Keep binary pixels out of the printed report. Root can pull these
        // neutral UI screenshots with adb run-as after the test completes.
        binding.reportData?.remove('screenshots');
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: previewKey,
            child: MaterialApp(
              theme: warmTheme(),
              home: Scaffold(
                appBar: AppBar(title: const Text('语音输出 · Android 验证')),
                body: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Eve · 中文女声',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text('收到回复后自动朗读，可在设置中关闭。'),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1E7E6),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(_sample),
                              SpeechMessageControl(
                                output: output,
                                message: messageId,
                                onPlay: () =>
                                    unawaited(output.play(messageId, _sample)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text('本次只生成一段测试语音；后续重播复用内存音频。'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final first = output.play(messageId, _sample);
        await waitFor(() => output.phase == SpeechOutputPhase.playing);
        expect(foregroundStarted, true);
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          events.any(
            (event) =>
                event.state == SpeechPlaybackState.playing &&
                event.position > Duration.zero,
          ),
          true,
        );
        expect(events.any((event) => event.duration > Duration.zero), true);
        expect(find.byKey(const Key('speech_voice_bars')), findsOneWidget);
        expect(find.text('正在朗读'), findsOneWidget);
        await capture('tts-native-playing');
        await waitFor(
          () => output.phase == SpeechOutputPhase.idle,
          seconds: 60,
        );
        await first;
        expect(
          events.any((event) => event.state == SpeechPlaybackState.completed),
          true,
        );
        expect(
          events.where((event) => event.state == SpeechPlaybackState.error),
          isEmpty,
        );
        expect(generated, isNotNull);
        expect(requests, 1);
        report['audio_bytes'] = generated!.length;
        report['duration_ms'] = events
            .where((event) => event.state == SpeechPlaybackState.completed)
            .last
            .duration
            .inMilliseconds;
        report['progress_events'] = events
            .where((event) => event.state == SpeechPlaybackState.playing)
            .length;
        report['completed'] = true;

        events.clear();
        final replay = output.play(messageId, _sample);
        await waitFor(
          () => output.phase == SpeechOutputPhase.playing,
          seconds: 15,
        );
        await tester.pump(const Duration(milliseconds: 350));
        await output.stop();
        await replay;
        await tester.pump(const Duration(milliseconds: 300));
        expect(output.phase, SpeechOutputPhase.idle);
        expect(events.last.state, SpeechPlaybackState.stopped);
        expect(requests, 1, reason: 'Replaying must use the cached MP3.');
        report['cached_replay_stopped'] = true;

        events.clear();
        final preparing = player.play(generated!);
        await player.stop();
        await preparing;
        final afterStop = events.length;
        await tester.pump(const Duration(seconds: 1));
        expect(
          events
              .skip(afterStop)
              .where((event) => event.state == SpeechPlaybackState.playing),
          isEmpty,
        );
        expect(requests, 1);
        report['cancel_prepare_no_late_playback'] = true;
        await capture('tts-native-stopped');
        expect(tester.takeException(), isNull);
        report['ok'] = true;
      } finally {
        report['tts_requests'] = requests;
        report['foreground_service_started'] = foregroundStarted;
        await output.stop(clearCache: true);
        await subscription.cancel();
        output.dispose();
        await player.dispose();
        await background.update(active: false);
        background.dispose();
        await tester.pumpWidget(const SizedBox());
        await File('${cache.path}/tts-native-report.json')
            .writeAsString(jsonEncode(report), flush: true);
        binding.reportData = {'tts_native': report};
        debugPrint('TTS_NATIVE_REPORT ${jsonEncode(report)}');
      }
    },
    skip: !const bool.fromEnvironment('VENICE_TTS_LIVE'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
