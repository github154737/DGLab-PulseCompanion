import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/speech_audio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/speech-playback');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> emit(Map<String, Object?> data) async {
    final delivered = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('event', data)),
      (_) => delivered.complete(),
    );
    await delivered.future;
    await Future<void>.delayed(Duration.zero);
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('progressive player accepts only tokenized localhost URLs', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final player = NativeSpeechAudioPlayer(channel: channel);
    final path = '/speech/${'a' * 64}.mp3';
    for (final value in [
      'https://example.com$path',
      'http://192.168.1.2:8000$path',
      'http://127.0.0.1:8000/secret',
      'http://127.0.0.1:8000$path?token=secret',
    ]) {
      await expectLater(
        player.playUrl(Uri.parse(value)),
        throwsA(isA<SpeechPlaybackException>()),
      );
    }
    expect(calls, isEmpty);
    await player.playUrl(Uri.parse('http://127.0.0.1:8000$path'));
    expect(calls.single.method, 'playUrl');
    expect(
      (calls.single.arguments as Map).keys,
      unorderedEquals(['id', 'url']),
    );
    await player.dispose();
  });

  test('stop during prepare rejects stale progress and a late start', () async {
    final prepare = Completer<void>();
    final requests = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'play') {
        requests.add((call.arguments as Map)['id'] as int);
        if (requests.length == 1) await prepare.future;
      }
      return null;
    });
    final player = NativeSpeechAudioPlayer(channel: channel);
    final events = <SpeechPlaybackEvent>[];
    final sub = player.events.listen(events.add);
    final oldPlay = player.play(Uint8List.fromList([73, 68, 51]));
    await Future<void>.delayed(Duration.zero);
    await player.stop();
    await player.play(Uint8List.fromList([73, 68, 51]));
    await emit({'id': requests.first, 'state': 'playing', 'positionMs': 100});
    await emit({
      'id': requests.last,
      'state': 'playing',
      'positionMs': 250,
      'durationMs': 800,
    });
    prepare.complete();
    await oldPlay;
    expect(events.map((e) => e.state), [
      SpeechPlaybackState.stopped,
      SpeechPlaybackState.playing,
    ]);
    expect(events.last.position.inMilliseconds, 250);
    expect(events.last.duration.inMilliseconds, 800);
    await player.dispose();
    await sub.cancel();
  });

  test(
    'focus or headphone interruption is terminal and does not resume',
    () async {
      int? id;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'play') id = (call.arguments as Map)['id'] as int;
        return null;
      });
      final player = NativeSpeechAudioPlayer(channel: channel);
      final events = <SpeechPlaybackEvent>[];
      final sub = player.events.listen(events.add);
      await player.play(Uint8List.fromList([73, 68, 51]));
      await emit({'id': id, 'state': 'playing'});
      await emit({'id': id, 'state': 'stopped'});
      await emit({'id': id, 'state': 'playing', 'positionMs': 1500});
      expect(events.map((e) => e.state), [
        SpeechPlaybackState.playing,
        SpeechPlaybackState.stopped,
      ]);
      await player.dispose();
      await sub.cancel();
    },
  );

  test('decoder error exposes only a local user message', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'play') {
        throw PlatformException(
          code: 'invalid_audio',
          message: '/private/audio/secret.mp3',
          details: 'private payload',
        );
      }
      return null;
    });
    final player = NativeSpeechAudioPlayer(channel: channel);
    final event = player.events.first;
    await expectLater(
      player.play(Uint8List.fromList([73, 68, 51])),
      throwsA(isA<SpeechPlaybackException>()),
    );
    expect((await event).message, '语音文件无法播放，请重新生成语音。');
    await player.dispose();
  });

  test('empty and oversized data never reaches native decoder', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return null;
    });
    final player = NativeSpeechAudioPlayer(channel: channel);
    await expectLater(
      player.play(Uint8List(0)),
      throwsA(isA<SpeechPlaybackException>()),
    );
    await expectLater(
      player.play(Uint8List(NativeSpeechAudioPlayer.maxAudioBytes + 1)),
      throwsA(isA<SpeechPlaybackException>()),
    );
    expect(calls, 0);
    await player.dispose();
  });

  test('completion is terminal and reports playback duration', () async {
    int? id;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'play') id = (call.arguments as Map)['id'] as int;
      return null;
    });
    final player = NativeSpeechAudioPlayer(channel: channel);
    final events = <SpeechPlaybackEvent>[];
    final sub = player.events.listen(events.add);
    await player.play(Uint8List.fromList([73, 68, 51]));
    await emit({
      'id': id,
      'state': 'completed',
      'positionMs': 920,
      'durationMs': 920,
    });
    await emit({'id': id, 'state': 'playing', 'positionMs': 930});
    expect(events.single.state, SpeechPlaybackState.completed);
    expect(events.single.duration.inMilliseconds, 920);
    await player.dispose();
    await sub.cancel();
  });

  test('late stop acknowledgement cannot stop a newer playback', () async {
    final stopped = Completer<void>();
    var deferStop = true;
    int? id;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'play') id = (call.arguments as Map)['id'] as int;
      if (call.method == 'stop' && deferStop) await stopped.future;
      return null;
    });
    final player = NativeSpeechAudioPlayer(channel: channel);
    final events = <SpeechPlaybackEvent>[];
    final sub = player.events.listen(events.add);
    await player.play(Uint8List.fromList([73, 68, 51]));
    final oldStop = player.stop();
    await player.play(Uint8List.fromList([73, 68, 51]));
    await emit({'id': id, 'state': 'playing'});
    stopped.complete();
    await oldStop;
    await Future<void>.delayed(Duration.zero);
    expect(events.map((e) => e.state), [SpeechPlaybackState.playing]);
    deferStop = false;
    await player.dispose();
    await sub.cancel();
  });
}
