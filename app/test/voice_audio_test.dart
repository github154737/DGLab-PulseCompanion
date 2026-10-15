
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/voice_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeVoiceAudio.channel, (call) async {
          calls.add(call);
          if (call.method == 'capacity') return 4800;
          if (call.method == 'pending') return 0;
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeVoiceAudio.channel, null),
  );
  test(
    'faster-than-realtime audio bursts drain through small native chunks',
    () async {
      final audio = NativeVoiceAudio();
      await audio.initializePlayback();
      await Future.wait(List.generate(6, (_) => audio.feed(Uint8List(24000))));
      final frames = calls
          .where((c) => c.method == 'feed')
          .map((c) => (c.arguments as Uint8List).length)
          .toList();
      expect(frames.fold<int>(0, (a, b) => a + b), 144000);
      expect(frames.every((n) => n <= 4800), true);
      await audio.dispose();
    },
  );
  test(
    'stop flushes software backlog and prevents delayed playback revival',
    () async {
      final audio = NativeVoiceAudio();
      await audio.initializePlayback();
      final pending = List.generate(8, (_) => audio.feed(Uint8List(48000)));
      await audio.stopPlayback();
      await Future.wait(pending);
      final atStop = calls.where((c) => c.method == 'feed').length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls.where((c) => c.method == 'feed').length, atStop);
      expect(await audio.pending(), 0);
      await audio.dispose();
    },
  );
}
