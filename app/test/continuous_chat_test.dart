import 'package:haptics_lab/app_access.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/continuous_voice.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/speech_audio_player.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_transcription.dart';
import 'package:haptics_lab/venice_tts.dart';

import 'continuous_voice_test.dart' as fixture;

class Stt extends VeniceTranscriber {
  Stt() : super(apiKey: 'test');
  int calls = 0;
  String text = '你好';
  bool empty = false;
  @override
  Future<String> transcribe(Uint8List wav) async {
    calls++;
    if (empty) throw const NoSpeechDetected();
    return text;
  }
}

class Chat extends ModelProvider {
  int calls = 0;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) async {
    calls++;
    return const ModelReply('你好，很高兴和你聊天。', {});
  }
}

class Tts extends VeniceTtsClient {
  Tts() : super(apiKey: 'test');
  bool fail = false;
  @override
  Future<Uint8List> synthesize(
    String text, {
    String voice = 'eve',
    double speed = 1,
  }) async {
    if (fail) throw const ModelServiceException('测试朗读失败', code: 'tts_http_502');
    return Uint8List.fromList([1, 2, 3]);
  }
}

class Player implements SpeechAudioPlayer {
  final stream = StreamController<SpeechPlaybackEvent>.broadcast(sync: true);
  int plays = 0;
  @override
  Stream<SpeechPlaybackEvent> get events => stream.stream;
  @override
  Future<void> play(Uint8List data) async {
    plays++;
    stream.add(const SpeechPlaybackEvent(SpeechPlaybackState.playing));
  }

  void complete() =>
      stream.add(const SpeechPlaybackEvent(SpeechPlaybackState.completed));
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await stream.close();
  }
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

void main() {
  testWidgets('real page keeps mic after empty STT and a failed TTS round', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final capture = fixture.Capture(),
        stt = Stt()..empty = true,
        chat = Chat(),
        player = Player(),
        tts = Tts()..fail = true;
    await tester.pumpWidget(
      MaterialApp(
        home: VeniceChatPage(
          role: AppRole.administrator,
          enableDialogueGuidance: false,
          loadKey: () async => 'fixture',
          continuousCapture: capture,
          transcriberFactory: (_) => stt,
          chatFactory: (_, _) => chat,
          ttsFactory: (_) => tts,
          speechPlayer: player,
        ),
      ),
    );
    await frames(tester);
    final dynamic state = tester.state(find.byType(VeniceChatPage));
    for (var i = 0; i < 60 && state.library.ready != true; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    state.library.funded = true;
    state.updateView(() {
      state.funded = true;
    });
    await frames(tester);
    await tester.tap(find.byKey(const Key('continuous_start')));
    await frames(tester);
    await tester.tap(find.byKey(const Key('continuous_confirm')));
    await frames(tester);
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() async {
        capture.phrase();
        await fixture.flush();
      });
      await frames(tester);
      await frames(tester);
      expect(state.continuous.phase, ContinuousPhase.listening);
      expect(capture.live, true);
      expect(chat.calls, 0);
      expect(player.plays, 0);
    }
    stt.empty = false;
    await tester.runAsync(() async {
      capture.phrase();
      await fixture.flush();
    });
    await frames(tester);
    await frames(tester);
    expect(chat.calls, 1);
    expect(player.plays, 0);
    expect(state.continuous.phase, ContinuousPhase.listening);
    expect(find.textContaining('本段朗读失败'), findsWidgets);
    expect(capture.live, true);
    tts.fail = false;
    await tester.runAsync(() async {
      capture.phrase();
      await fixture.flush();
    });
    await frames(tester);
    expect(chat.calls, 2);
    expect(player.plays, 1);
    await tester.tap(find.byKey(const Key('continuous_end')));
    await frames(tester);
    expect(capture.live, false);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  });
  for (final background in [false, true]) {
    for (final bargeIn in [false, true]) {
      testWidgets(
        'continuous loop, interrupt and background $background / barge-in $bargeIn',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final capture = fixture.Capture(),
              stt = Stt(),
              chat = Chat(),
              player = Player();
          await tester.pumpWidget(
            MaterialApp(
              home: VeniceChatPage(
                role: AppRole.administrator,
                enableDialogueGuidance: false,
                loadKey: () async => 'fixture',
                continuousCapture: capture,
                transcriberFactory: (_) => stt,
                chatFactory: (_, _) => chat,
                ttsFactory: (_) => Tts(),
                speechPlayer: player,
              ),
            ),
          );
          await frames(tester);
          final dynamic state = tester.state(find.byType(VeniceChatPage));
          // Wait for asynchronous local library restore before setting test consent.
          for (var i = 0; i < 60 && state.library.ready != true; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)),
            );
            await tester.pump();
          }
          state.library.funded = true;
          state.updateView(() {
            state.funded = true;
          });
          await frames(tester);
          await tester.tap(find.byKey(const Key('continuous_start')));
          await frames(tester);
          expect(find.text('开启连续对话'), findsOneWidget);
          // Keep regression coverage for the explicit half-duplex fallback.
          if (!bargeIn) {
            await tester.tap(find.byKey(const Key('continuous_barge_in')));
          }
          await frames(tester);
          if (background) {
            await tester.tap(find.byKey(const Key('continuous_background')));
            await tester.pump();
          }
          await tester.tap(find.byKey(const Key('continuous_confirm')));
          await frames(tester);
          expect(capture.live, true);
          expect(find.byKey(const Key('venice_message')), findsNothing);
          await tester.runAsync(() async {
            capture.phrase();
            await fixture.flush();
          });
          await frames(tester);
          expect(
            stt.calls,
            1,
            reason:
                '${state.continuous.phase}: ${state.continuous.notice}; ${state.status}; pcm=${state.continuous.detector.retainedBytes} live=${capture.live} starts=${capture.starts} stops=${capture.stops} listener=${capture.stream!.hasListener}',
          );
          expect(chat.calls, 1);
          expect(player.plays, 1);
          expect(capture.live, bargeIn);
          expect(find.text('打断并说话'), findsOneWidget);
          expect(
            tester.getSize(find.byKey(const Key('chat_messages'))).height,
            greaterThan(400),
          );
          if (bargeIn) {
            await tester.runAsync(() async {
              capture.phrase();
              await fixture.flush();
            });
            await frames(tester);
            expect(chat.calls, 2);
            expect(player.plays, 2);
            expect(capture.starts, 1);
            expect(capture.live, true);
          }
          await tester.binding.setSurfaceSize(const Size(320, 640));
          await frames(tester);
          expect(tester.takeException(), isNull);
          await tester.binding.setSurfaceSize(const Size(390, 844));
          await frames(tester);
          await tester.tap(find.byKey(const Key('continuous_interrupt')));
          await frames(tester);
          expect(capture.live, true);
          expect(capture.starts, 2);
          // Completing a cancelled player must not start a second recorder.
          player.complete();
          await frames(tester);
          expect(capture.starts, 2);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await frames(tester);
          expect(capture.live, background);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await frames(tester);
          if (!background) {
            await tester.tap(find.byKey(const Key('continuous_resume')));
            await frames(tester);
          }
          await tester.runAsync(() async {
            capture.phrase();
            await fixture.flush();
          });
          await frames(tester);
          expect(player.plays, bargeIn ? 3 : 2);
          if (background) {
            player.stream.add(
              const SpeechPlaybackEvent(SpeechPlaybackState.stopped),
            );
            await frames(tester);
            expect(capture.live, false);
            expect(find.byKey(const Key('continuous_resume')), findsOneWidget);
            await tester.tap(find.byKey(const Key('continuous_resume')));
          } else {
            player.complete();
          }
          await frames(tester);
          expect(capture.live, true);
          await tester.tap(find.byKey(const Key('continuous_mute')));
          await frames(tester);
          expect(capture.live, false);
          await tester.tap(find.byKey(const Key('continuous_end')));
          await frames(tester);
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('venice_message')))
                .enabled,
            true,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await frames(tester);
        },
      );
    }
  }
}
