import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/continuous_voice.dart';

import 'continuous_voice_test.dart' as fixture;

void main() {
  test(
    'barge-in stops reply before end of speech and preserves first samples',
    () async {
      final capture = fixture.Capture();
      final replies = [Completer<void>(), Completer<void>()];
      final uploaded = <Uint8List>[];
      var calls = 0, interrupts = 0;
      final voice = ContinuousVoice(
        capture: capture,
        prepare: () async => true,
        transcribe: (wav) async {
          uploaded.add(wav);
          return '新的话';
        },
        reply: (_) => replies[calls++].future,
        cancelWork: () async {},
        interruptReply: () async {
          interrupts++;
        },
        echoDelay: Duration.zero,
      )..bargeIn = true;
      await voice.start();
      await fixture.flush();
      capture.phrase();
      await fixture.flush();
      voice.speaking();
      expect(capture.live, true);
      expect(voice.phase, ContinuousPhase.speaking);
      // A click must not interrupt.
      capture.stream!.add(fixture.tone(100));
      capture.stream!.add(Uint8List(32000));
      await fixture.flush();
      expect(interrupts, 0);
      final phrase = fixture.tone(600);
      capture.stream!.add(phrase);
      await fixture.flush();
      expect(interrupts, 1);
      expect(
        uploaded,
        hasLength(1),
      ); // Stop playback before uploading the phrase.
      expect(voice.phase, ContinuousPhase.listening);
      replies[0].complete(); // A stale response cannot reset the microphone.
      await fixture.flush();
      expect(voice.phase, ContinuousPhase.listening);
      capture.stream!.add(Uint8List(32000));
      await fixture.flush();
      expect(calls, 2);
      expect(uploaded, hasLength(2));
      final pcm = uploaded[1].sublist(44);
      // The buffered first syllable is retained, not restarted after cancellation.
      expect(pcm.join(','), contains(phrase.sublist(0, 640).join(',')));
      expect(capture.starts, 1);
      await voice.pause();
      replies[1].complete();
      await fixture.flush();
      expect(capture.live, false);
      expect(voice.phase, ContinuousPhase.paused);
      voice.dispose();
    },
  );

  test('barge-in mute during STT suppresses a late reply', () async {
    final capture = fixture.Capture(), stt = Completer<String>();
    var replies = 0;
    final voice = ContinuousVoice(
      capture: capture,
      prepare: () async => true,
      transcribe: (_) => stt.future,
      reply: (_) async {
        replies++;
      },
      cancelWork: () async {},
    )..bargeIn = true;
    await voice.start();
    await fixture.flush();
    capture.phrase();
    await fixture.flush();
    await voice.end();
    stt.complete('迟到的识别');
    await fixture.flush();
    expect(replies, 0);
    expect(capture.live, false);
    voice.dispose();
  });

  test('permission completion after ending duplex closes mic', () async {
    final capture = fixture.Capture()..permission = Completer<void>();
    final voice = ContinuousVoice(
      capture: capture,
      prepare: () async => true,
      transcribe: (_) async => '',
      reply: (_) async {},
      cancelWork: () async {},
    )..bargeIn = true;
    await voice.start();
    await fixture.flush();
    final ended = voice.end();
    capture.permission!.complete();
    await ended;
    expect(capture.live, false);
    voice.dispose();
  });

  test(
    'echo guard applies only to long matching speech, not short commands',
    () {
      expect(resemblesPlaybackEcho('你好，今天过得怎么样呀？', '你好今天过得怎么样呀'), true);
      expect(resemblesPlaybackEcho('调低一点', '那我调低一点，现在感觉怎么样'), false);
      expect(resemblesPlaybackEcho('我想先聊聊今天发生的事情', '你好今天过得怎么样呀'), false);
    },
  );
}
