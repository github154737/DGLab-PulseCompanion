import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_recorder.dart';

class CaptureFixture implements SpeechCapture {
  final stream = StreamController<Uint8List>();
  Completer<void>? gate;
  int stops = 0;
  @override
  Future<Stream<Uint8List>> start() async {
    await gate?.future;
    return stream.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  test('local capture stops into bounded WAV and clears on discard', () async {
    final capture = CaptureFixture();
    final recorder = VeniceRecorder(capture: capture);
    addTearDown(recorder.dispose);
    await recorder.start();
    capture.stream.add(Uint8List(6400));
    await Future<void>.delayed(Duration.zero);
    await recorder.stop();
    expect(recorder.phase, RecordingPhase.ready);
    expect(recorder.wav().length, 6444);
    expect(capture.stops, 1);
    await recorder.discard();
    expect(recorder.byteCount, 0);
    expect(recorder.phase, RecordingPhase.idle);
    await capture.stream.close();
  });
  test(
    'cancel during delayed microphone permission cannot revive recording',
    () async {
      final capture = CaptureFixture()..gate = Completer<void>();
      final recorder = VeniceRecorder(capture: capture);
      addTearDown(recorder.dispose);
      final start = recorder.start();
      final discard = recorder.discard();
      capture.gate!.complete();
      await start;
      await discard;
      expect(recorder.phase, RecordingPhase.idle);
      expect(recorder.byteCount, 0);
      expect(capture.stops, greaterThanOrEqualTo(1));
    },
  );
  test('maximum audio size stops locally without any upload', () async {
    final capture = CaptureFixture();
    final recorder = VeniceRecorder(capture: capture);
    addTearDown(recorder.dispose);
    await recorder.start();
    capture.stream.add(Uint8List(1920100));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(recorder.phase, RecordingPhase.ready);
    expect(recorder.byteCount, 1920000);
    expect(recorder.wav().length, 1920044);
    await capture.stream.close();
  });
  test('unexpected microphone end produces an error instead of submitting partial audio', () async {
    final capture = CaptureFixture();
    final recorder = VeniceRecorder(capture: capture);
    addTearDown(recorder.dispose);
    await recorder.start();
    capture.stream.add(Uint8List(6400));
    unawaited(capture.stream.close());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(recorder.phase, RecordingPhase.failed);
    expect(recorder.byteCount, 0);
    expect(recorder.error, isNotEmpty);
  });
}
