import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/continuous_voice.dart';
import 'package:haptics_lab/venice_recorder.dart';

Uint8List tone(int ms) {
  final bytes = Uint8List(ms * 32);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < bytes.length ~/ 2; i++) {
    data.setInt16(i * 2, (sin(i * .15) * 5000).round(), Endian.little);
  }
  return bytes;
}

class Capture implements SpeechCapture {
  StreamController<Uint8List>? stream;
  int starts = 0, stops = 0;
  bool live = false, denied = false;
  Completer<void>? permission;
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    await permission?.future;
    if (denied) throw StateError('permission_denied');
    live = true;
    stream = StreamController<Uint8List>();
    return stream!.stream;
  }

  @override
  Future<void> stop() async {
    live = false;
    stops++;
  }

  void phrase() {
    stream!.add(tone(500));
    stream!.add(Uint8List(32000));
  }
}

Future<void> flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('silence is bounded and click does not produce an utterance', () {
    final vad = VoiceEndpoint();
    for (var i = 0; i < 600; i++) {
      expect(vad.add(Uint8List(32000)), isNull);
    }
    expect(vad.retainedBytes, lessThanOrEqualTo(16000));
    expect(vad.add(tone(100)), isNull);
    expect(vad.add(Uint8List(32000)), isNull);
  });
  test('fragmented PCM preserves pre-roll and waits for a natural pause', () {
    final vad = VoiceEndpoint();
    final pcm = tone(600);
    for (var i = 0; i < pcm.length; i += 333) {
      expect(
        vad.add(Uint8List.sublistView(pcm, i, min(i + 333, pcm.length))),
        isNull,
      );
    }
    expect(vad.add(Uint8List(3200)), isNull);
    final segment = vad.add(Uint8List(32000));
    expect(segment, isNotNull);
    expect(segment!.length, greaterThan(32000));
    expect(vad.retainedBytes, 0);
  });
  test('continuous sound is capped to a bounded utterance', () {
    final segment = VoiceEndpoint().add(tone(25000));
    expect(segment, isNotNull);
    expect(segment!.length, lessThan(660000));
  });
  test(
    'capture stops before upload, waits for reply then listens again',
    () async {
      final capture = Capture();
      final answer = Completer<void>();
      var uploads = 0, replies = 0;
      final voice = ContinuousVoice(
        capture: capture,
        prepare: () async => true,
        transcribe: (wav) async {
          expect(capture.live, false);
          uploads++;
          expect(wav.length, greaterThan(44));
          return '你好';
        },
        reply: (_) async {
          replies++;
          await answer.future;
        },
        cancelWork: () async {},
        echoDelay: Duration.zero,
      );
      await voice.start();
      await flush();
      capture.stream!.add(Uint8List(32000));
      await flush();
      expect(uploads, 0);
      capture.phrase();
      await flush();
      expect(uploads, 1);
      expect(replies, 1);
      expect(capture.live, false);
      expect(voice.phase, ContinuousPhase.replying);
      answer.complete();
      await flush();
      expect(capture.starts, 2);
      expect(voice.phase, ContinuousPhase.listening);
      await voice.end();
      voice.dispose();
    },
  );
  test(
    'mute discards audio and late transcription cannot invoke reply',
    () async {
      final capture = Capture();
      final stt = Completer<String>();
      var replies = 0;
      final voice = ContinuousVoice(
        capture: capture,
        prepare: () async => true,
        transcribe: (_) => stt.future,
        reply: (_) async {
          replies++;
        },
        cancelWork: () async {},
      );
      await voice.start();
      await flush();
      capture.phrase();
      await flush();
      await voice.pause();
      stt.complete('迟到的话');
      await flush();
      expect(replies, 0);
      expect(voice.phase, ContinuousPhase.paused);
      expect(capture.live, false);
      voice.dispose();
    },
  );
  test(
    'end during permission request closes late capture and never uploads',
    () async {
      final capture = Capture()..permission = Completer<void>();
      var uploads = 0;
      final voice = ContinuousVoice(
        capture: capture,
        prepare: () async => true,
        transcribe: (_) async {
          uploads++;
          return '';
        },
        reply: (_) async {},
        cancelWork: () async {},
      );
      await voice.start();
      await flush();
      final ended = voice.end();
      capture.permission!.complete();
      await ended;
      await flush();
      expect(capture.live, false);
      expect(uploads, 0);
      expect(voice.phase, ContinuousPhase.off);
      voice.dispose();
    },
  );
  for (final cause in [
    'permission',
    'service',
    'capture',
    'network',
    'reply',
  ]) {
    test('$cause failure pauses without automatic retry', () async {
      final capture = Capture()..denied = cause == 'permission';
      final voice = ContinuousVoice(
        capture: capture,
        prepare: () async => cause != 'service',
        transcribe: (_) async {
          if (cause == 'network') throw StateError('offline');
          return '你好';
        },
        reply: (_) async {
          throw StateError('reply_failed');
        },
        cancelWork: () async {},
      );
      await voice.start();
      await flush();
      if (cause == 'capture') {
        capture.stream!.addError(StateError('interrupted'));
      }
      if (cause == 'network' || cause == 'reply') {
        capture.phrase();
      }
      await flush();
      expect(voice.phase, ContinuousPhase.paused);
      expect(capture.live, false);
      expect(capture.starts, 1);
      voice.dispose();
    });
  }
}
