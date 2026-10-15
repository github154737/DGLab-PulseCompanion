import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/continuous_voice.dart';
import 'package:haptics_lab/venice_transcription.dart';
import 'package:haptics_lab/chat_stream.dart';
import 'package:haptics_lab/speech_output.dart';
import 'package:haptics_lab/network_diagnostics.dart';

import 'continuous_voice_test.dart' as fixture;

void main() {
  for (final duplex in [false, true]) {
    test(
      'empty STT keeps listening then accepts speech / duplex $duplex',
      () async {
        final capture = fixture.Capture();
        var calls = 0, replies = 0;
        final voice = ContinuousVoice(
          capture: capture,
          prepare: () async => true,
          transcribe: (_) async {
            calls++;
            if (calls <= 4) throw const NoSpeechDetected();
            return '停';
          },
          reply: (text) async {
            expect(text, '停');
            replies++;
          },
          cancelWork: () async {},
          echoDelay: Duration.zero,
          noSpeechDelay: Duration.zero,
        )..bargeIn = duplex;
        await voice.start();
        await fixture.flush();
        for (var i = 0; i < 5; i++) {
          capture.phrase();
          await fixture.flush();
          expect(voice.phase, ContinuousPhase.listening);
          expect(capture.live, true);
        }
        expect(calls, 5);
        expect(replies, 1);
        await voice.end();
        voice.dispose();
      },
    );

    test('TTS failure recovers twice then pauses / duplex $duplex', () async {
      final capture = fixture.Capture();
      var replies = 0;
      final voice = ContinuousVoice(
        capture: capture,
        prepare: () async => true,
        transcribe: (_) async => '你好',
        reply: (_) async {
          replies++;
          throw const ContinuousPlaybackFailure('tts_http_502');
        },
        cancelWork: () async {},
        echoDelay: Duration.zero,
      )..bargeIn = duplex;
      await voice.start();
      await fixture.flush();
      for (var i = 0; i < 3; i++) {
        capture.phrase();
        await fixture.flush();
        expect(
          voice.phase,
          i == 2 ? ContinuousPhase.paused : ContinuousPhase.listening,
        );
      }
      expect(replies, 3);
      expect(capture.live, false);
      await voice.end();
      voice.dispose();
    });
  }

  test('permission/balance playback failure does not auto-resume', () async {
    final capture = fixture.Capture();
    final voice = ContinuousVoice(
      capture: capture,
      prepare: () async => true,
      transcribe: (_) async => '你好',
      reply: (_) async => throw const ContinuousPlaybackFailure(
        'tts_http_402',
        recoverable: false,
      ),
      cancelWork: () async {},
    )..bargeIn = true;
    await voice.start();
    await fixture.flush();
    capture.phrase();
    await fixture.flush();
    expect(voice.phase, ContinuousPhase.paused);
    expect(capture.live, false);
    await voice.end();
    voice.dispose();
  });

  test(
    'vocalization guard preserves clear commands and ordinary sentences',
    () {
      for (final value in [
        '嗯',
        '嗯嗯啊',
        '哼～',
        '啊？',
        'Yeah.',
        'hmm...',
        'Uh huh',
        'OK',
      ]) {
        // Uh huh is intentionally included as a short acknowledgement.
        expect(isVocalizationOnly(value), true, reason: value);
      }
      for (final value in [
        '停',
        '不要',
        '降低一点',
        '嗯，调到十',
        '啊，好疼',
        '今天很好',
        'stop',
      ]) {
        expect(isVocalizationOnly(value), false, reason: value);
      }
    },
  );

  test('technical note is never spoken across any incremental boundary', () {
    const full = '好的。\n（注：此处进行了模拟调整，因实际设备未执行而未涉及具体波形。）\n我们继续聊。';
    final split = SpeechSentences();
    final spoken = <String>[];
    for (var i = 1; i <= full.length; i++) {
      spoken.addAll(
        split.add(full.substring(0, i)).map(SpeechOutput.spokenText),
      );
    }
    spoken.addAll(split.add(full, complete: true).map(SpeechOutput.spokenText));
    expect(spoken.join(), isNot(contains('模拟')));
    expect(spoken.join(), contains('好的。'));
    expect(spoken.join(), contains('我们继续聊。'));
    expect(SpeechOutput.spokenText(full), isNot(contains('实际设备')));
    expect(SpeechOutput.spokenText('你好（今天有点冷）。\n注：明天记得带伞。'), contains('今天有点冷'));
    expect(SpeechOutput.spokenText('注：明天记得带伞。'), contains('带伞'));
  });

  test('diagnostic ring retains useful history but is bounded', () {
    final trace = NetworkTrace('测试边界');
    for (var i = 0; i < 1300; i++) {
      trace.mark('编号 $i');
    }
    expect(NetworkTrace.report, contains('编号 1299'));
    expect(NetworkTrace.report, isNot(contains('编号 99\n')));
    expect(NetworkTrace.report.split('\n').length, lessThanOrEqualTo(1202));
  });
}
