import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/speech_audio_player.dart';
import 'package:haptics_lab/speech_output.dart';
import 'package:haptics_lab/venice_tts.dart';

class SynthesisCall {
  SynthesisCall(this.text, this.voice, this.speed);
  final String text, voice;
  final double speed;
  final result = Completer<Uint8List>();
  bool cancelled = false;
}

class ControlledTts extends VeniceTtsClient {
  ControlledTts(this.calls, {this.automatic = false})
    : super(apiKey: 'fixture');
  final List<SynthesisCall> calls;
  final bool automatic;
  SynthesisCall? current;

  @override
  Future<Uint8List> synthesize(
    String text, {
    String voice = 'eve',
    double speed = 1,
  }) {
    final call = SynthesisCall(text, voice, speed);
    calls.add(call);
    current = call;
    if (automatic) {
      call.result.complete(Uint8List.fromList([1, calls.length, 3]));
    }
    return call.result.future;
  }

  @override
  void cancel() {
    // Intentionally allow a response after cancellation: generation tokens in
    // SpeechOutput must reject late results even when a transport cannot abort.
    current?.cancelled = true;
  }
}

class ControlledPlayer implements SpeechAudioPlayer {
  final eventsController = StreamController<SpeechPlaybackEvent>.broadcast(
    sync: true,
  );
  final played = <Uint8List>[];
  int stops = 0;
  bool disposed = false;
  bool completeImmediately = false;
  Completer<void>? stopGate, prepareGate;
  Object? playFailure;

  @override
  Stream<SpeechPlaybackEvent> get events => eventsController.stream;

  void emit(SpeechPlaybackState state, {String? message}) {
    eventsController.add(
      SpeechPlaybackEvent(
        state,
        position: const Duration(seconds: 1),
        duration: const Duration(seconds: 4),
        message: message,
      ),
    );
  }

  @override
  Future<void> play(Uint8List bytes) async {
    played.add(bytes);
    if (playFailure != null) throw playFailure!;
    final gate = prepareGate;
    if (gate != null) await gate.future;
    emit(SpeechPlaybackState.playing);
    if (completeImmediately) emit(SpeechPlaybackState.completed);
  }

  @override
  Future<void> stop() async {
    stops++;
    final gate = stopGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await eventsController.close();
  }
}

class SpeechHarness {
  SpeechHarness({bool automatic = false, bool ready = true}) {
    output = SpeechOutput(
      createClient: () => ControlledTts(calls, automatic: automatic),
      player: player,
      preparePlayback: () async {
        preparations++;
        return ready;
      },
    );
  }
  final calls = <SynthesisCall>[];
  final player = ControlledPlayer();
  late final SpeechOutput output;
  int preparations = 0;

  Future<void> dispose() async {
    output.dispose();
    await pumpEventQueue();
  }
}

class StreamingTts extends VeniceTtsClient {
  StreamingTts(this.release) : super(apiKey: 'fixture');
  final Completer<void> release;
  @override
  Future<Uint8List> synthesize(
    String text, {
    String voice = 'eve',
    double speed = 1,
  }) async {
    final part = Uint8List.fromList([
      0xff,
      0xfb,
      0x90,
      0x64,
      ...List.filled(124, 0),
    ]);
    await onAudioChunk!(part);
    await release.future;
    await onAudioChunk!(part);
    return Uint8List.fromList([...part, ...part]);
  }
}

class StreamingPlayer extends ControlledPlayer
    implements ProgressiveSpeechPlayer {
  final first = Completer<void>();
  final client = HttpClient();
  final bytes = <int>[];
  @override
  Future<void> playUrl(Uri uri) async {
    final response = await (await client.getUrl(uri)).close();
    response.listen(
      (part) {
        bytes.addAll(part);
        emit(SpeechPlaybackState.playing);
        if (!first.isCompleted) first.complete();
      },
      onDone: () => emit(SpeechPlaybackState.completed),
      onError: (_) {},
    );
    await first.future;
  }

  @override
  Future<void> dispose() async {
    client.close(force: true);
    await super.dispose();
  }
}

class SegmentStreamingPlayer extends ControlledPlayer
    implements ProgressiveSpeechPlayer {
  int starts = 0;
  final client = HttpClient();
  @override
  Future<void> playUrl(Uri uri) async {
    starts++;
    final first = Completer<void>();
    final response = await (await client.getUrl(uri)).close();
    response.listen((_) {
      emit(SpeechPlaybackState.playing);
      if (!first.isCompleted) first.complete();
    }, onError: (_) {});
    await first.future;
  }

  @override
  Future<void> dispose() async {
    client.close(force: true);
    await super.dispose();
  }
}

void main() {
  test(
    'prefetched progressive segment plays before its download ends',
    () async {
      final gates = [Completer<void>(), Completer<void>()];
      var calls = 0;
      final player = SegmentStreamingPlayer();
      final output = SpeechOutput(
        createClient: () => StreamingTts(gates[calls++]),
        player: player,
        preparePlayback: () async => true,
      );
      addTearDown(() {
        for (final gate in gates) {
          if (!gate.isCompleted) gate.complete();
        }
        output.dispose();
      });
      final sentences = StreamController<String>();
      final run = output.play(Object(), '', sentences: sentences.stream);
      sentences.add('第一句。');
      sentences.add('第二句。');
      await pumpEventQueue(times: 40);
      expect(player.starts, 1);
      gates[0].complete();
      await pumpEventQueue(times: 40);
      expect(calls, 2);
      expect(player.starts, 1);
      player.emit(SpeechPlaybackState.completed);
      await pumpEventQueue(times: 40);
      expect(player.starts, 2);
      expect(gates[1].isCompleted, isFalse);
      expect(output.phase, SpeechOutputPhase.playing);
      await output.stop();
      await run.timeout(const Duration(seconds: 2));
      gates[1].complete();
      await sentences.close();
    },
  );

  test(
    'output pipeline starts progressive playback while TTS is still generating',
    () async {
      final release = Completer<void>();
      final player = StreamingPlayer();
      final output = SpeechOutput(
        createClient: () => StreamingTts(release),
        player: player,
        preparePlayback: () async => true,
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        output.dispose();
      });
      final run = output.play(Object(), '你好。');
      await player.first.future.timeout(const Duration(seconds: 2));
      expect(output.phase, SpeechOutputPhase.playing);
      expect(player.bytes, hasLength(128));
      expect(
        player.played,
        isEmpty,
        reason: 'must not fall back to buffered playback',
      );
      release.complete();
      await run;
      expect(player.bytes, hasLength(256));
      expect(output.phase, SpeechOutputPhase.idle);
    },
  );

  test(
    'sentence stream plays first sentence before final text exactly once',
    () async {
      final h = SpeechHarness(automatic: true);
      addTearDown(h.dispose);
      h.player.completeImmediately = true;
      final sentences = StreamController<String>();
      final run = h.output.play(Object(), '', sentences: sentences.stream);
      sentences.add('第一句。');
      await pumpEventQueue();
      expect(h.calls.map((c) => c.text), ['第一句。']);
      expect(h.player.played, hasLength(1));
      sentences.add('第二句。');
      await sentences.close();
      await run;
      expect(h.calls.map((c) => c.text), ['第一句。', '第二句。']);
      expect(h.player.played, hasLength(2));
      expect(h.output.phase, SpeechOutputPhase.idle);
    },
  );

  test('stop while waiting for next sentence prevents late audio', () async {
    final h = SpeechHarness(automatic: true);
    addTearDown(h.dispose);
    h.player.completeImmediately = true;
    final sentences = StreamController<String>();
    final run = h.output.play(Object(), '', sentences: sentences.stream);
    sentences.add('第一句。');
    await pumpEventQueue();
    await h.output.stop();
    await run.timeout(const Duration(seconds: 2));
    sentences.add('旧回复晚到的第二句。');
    await sentences.close();
    await pumpEventQueue();
    expect(h.calls, hasLength(1));
    expect(h.player.played, hasLength(1));
    expect(h.output.phase, SpeechOutputPhase.idle);
  });

  test('one segment is prefetched while playing; third waits and stop cancels prefetch', () async {
    final h = SpeechHarness();
    addTearDown(h.dispose);
    final input = StreamController<String>();
    final run = h.output.play(Object(), '', sentences: input.stream);
    input.add('第一句。');
    input.add('第二句。');
    input.add('第三句。');
    await pumpEventQueue();
    h.calls[0].result.complete(Uint8List.fromList([1, 2, 3]));
    await pumpEventQueue();
    expect(h.calls.map((c) => c.text), ['第一句。', '第二句。']);
    expect(h.player.played, hasLength(1));
    h.calls[1].result.complete(Uint8List.fromList([4, 5, 6]));
    await pumpEventQueue();
    expect(h.player.played, hasLength(1));
    h.player.emit(SpeechPlaybackState.completed);
    await pumpEventQueue();
    expect(h.player.played, hasLength(2));
    expect(h.calls, hasLength(3));
    await h.output.stop();
    await run.timeout(const Duration(seconds: 2));
    expect(h.calls.last.cancelled, isTrue);
    h.calls.last.result.complete(Uint8List.fromList([7, 8, 9]));
    await input.close();
    await pumpEventQueue();
    expect(h.player.played, hasLength(2));
    expect(h.output.phase, SpeechOutputPhase.idle);
  });

  test(
    'prefetch failure waits for current speech, never auto-retries',
    () async {
      final h = SpeechHarness();
      addTearDown(h.dispose);
      final run = h.output.play(Object(), '字' * 1500);
      await pumpEventQueue();
      h.calls[0].result.complete(Uint8List.fromList([1, 2, 3]));
      await pumpEventQueue();
      h.calls[1].result.completeError(const ModelServiceException('预取网络中断。'));
      await pumpEventQueue();
      expect(h.output.phase, SpeechOutputPhase.playing);
      h.player.emit(SpeechPlaybackState.completed);
      await run;
      expect(h.output.phase, SpeechOutputPhase.failed);
      expect(h.calls, hasLength(2));
      expect(h.player.played, hasLength(1));
    },
  );

  group('speech text boundary', () {
    test(
      'only readable reply reaches synthesis; control data and code do not',
      () async {
        final h = SpeechHarness(automatic: true);
        addTearDown(h.dispose);
        h.player.completeImmediately = true;
        await h.output.play(
          Object(),
          '[[CTRL {"a":20,"b":10,"mode":"wave"}]]\n'
          '**你好**，请看[帮助](https://example.invalid/help)。\n'
          '```json\n{"action":"set_intensity","level":20}\n```\n'
          'https://example.invalid/private\n再见。',
        );
        expect(h.calls.single.text, '你好，请看帮助。\n\n\n再见。');
        expect(h.calls.single.voice, 'eve');
        expect(h.calls.single.speed, 1);
        expect(h.output.phase, SpeechOutputPhase.idle);
        expect(h.player.played, hasLength(1));
      },
    );

    test('incomplete machine blocks and fences are never read aloud', () {
      expect(SpeechOutput.spokenText('你好。[[CTRL {"a":20'), '你好。');
      expect(SpeechOutput.spokenText('你好。```json\n{"a":20'), '你好。');
    });

    test(
      'long text splits in order without splitting Unicode characters',
      () async {
        final h = SpeechHarness(automatic: true);
        addTearDown(h.dispose);
        h.player.completeImmediately = true;
        final original =
            '${List.filled(650, '好').join()}。'
            '${List.filled(500, '🙂').join()}！'
            '${List.filled(900, '听').join()}。';
        final parts = SpeechOutput.splitText(original);
        expect(parts.first, endsWith('。'));
        expect(parts.join(), original);
        expect(parts.every((p) => p.runes.length <= 1000), isTrue);
        expect(parts.every((p) => !p.contains('\uFFFD')), isTrue);
        await h.output.play(Object(), original);
        expect(h.calls.map((c) => c.text), orderedEquals(parts));
        expect(h.player.played, hasLength(parts.length));
        expect(h.output.segment, parts.length);
        expect(h.output.segments, parts.length);
      },
    );

    test(
      'empty or excessive readable text does not make paid requests',
      () async {
        final h = SpeechHarness();
        addTearDown(h.dispose);
        await h.output.play(Object(), '[[CTRL {"a":0}]]');
        expect(h.output.phase, SpeechOutputPhase.failed);
        expect(h.output.error, contains('没有可朗读'));
        await h.output.play(Object(), List.filled(12001, '字').join());
        expect(h.output.phase, SpeechOutputPhase.failed);
        expect(h.output.error, contains('过长'));
        expect(h.calls, isEmpty);
        expect(h.preparations, 0);
      },
    );
  });

  group('cancellation and concurrency', () {
    test('scheduled speech is active immediately and replacement never publishes idle', () async {
      final h = SpeechHarness(automatic: true);
      addTearDown(h.dispose);
      final phases = <SpeechOutputPhase>[];
      h.output.addListener(() => phases.add(h.output.phase));
      final first = h.output.play(Object(), '第一条回复。');
      expect(
        h.output.active,
        isTrue,
        reason: 'foreground service ownership must be synchronous',
      );
      expect(phases, [SpeechOutputPhase.generating]);
      await pumpEventQueue();
      expect(h.output.phase, SpeechOutputPhase.playing);

      phases.clear();
      final gate = Completer<void>();
      h.player.stopGate = gate;
      final replacementMessage = Object();
      final second = h.output.play(replacementMessage, '第二条回复。');
      expect(h.output.active, isTrue);
      expect(h.output.message, same(replacementMessage));
      expect(phases, [SpeechOutputPhase.generating]);
      await pumpEventQueue();
      expect(
        h.calls,
        hasLength(1),
        reason: 'new request waits for native stop',
      );
      expect(phases, isNot(contains(SpeechOutputPhase.idle)));
      gate.complete();
      await pumpEventQueue();
      expect(h.calls, hasLength(2));
      expect(h.output.phase, SpeechOutputPhase.playing);
      expect(phases, isNot(contains(SpeechOutputPhase.idle)));

      final stopped = h.output.stop();
      expect(
        h.output.active,
        isFalse,
        reason: 'explicit stop still releases ownership immediately',
      );
      expect(phases.last, SpeechOutputPhase.idle);
      await Future.wait([first, second, stopped]);
    });

    test('late response after stop cannot play or repopulate cache', () async {
      final h = SpeechHarness();
      addTearDown(h.dispose);
      final first = h.output.play(Object(), '这是迟到的回复。');
      await pumpEventQueue();
      expect(h.calls, hasLength(1));
      expect(h.output.phase, SpeechOutputPhase.generating);
      await h.output.stop(clearCache: true);
      expect(h.calls.single.cancelled, isTrue);
      h.calls.single.result.complete(Uint8List.fromList([1, 2, 3]));
      await first;
      expect(h.player.played, isEmpty);
      expect(h.output.phase, SpeechOutputPhase.idle);
      expect(h.output.message, isNull);

      h.player.completeImmediately = true;
      final second = h.output.play(Object(), '这是迟到的回复。');
      await pumpEventQueue();
      expect(
        h.calls,
        hasLength(2),
        reason: 'cancelled response must not enter cache',
      );
      h.calls.last.result.complete(Uint8List.fromList([4, 5, 6]));
      await second;
      expect(h.player.played.single, orderedEquals([4, 5, 6]));
    });

    test(
      'a new reply wins even if an older synthesis completes last',
      () async {
        final h = SpeechHarness();
        addTearDown(h.dispose);
        final old = h.output.play(Object(), '旧回复。');
        await pumpEventQueue();
        final newMessage = Object();
        final current = h.output.play(newMessage, '新回复。');
        await pumpEventQueue();
        expect(h.calls, hasLength(2));
        expect(h.calls.first.cancelled, isTrue);
        h.calls.last.result.complete(Uint8List.fromList([9]));
        await pumpEventQueue();
        expect(h.output.message, same(newMessage));
        expect(h.output.phase, SpeechOutputPhase.playing);
        h.calls.first.result.complete(Uint8List.fromList([1]));
        await old;
        expect(h.player.played.single, orderedEquals([9]));
        expect(h.output.message, same(newMessage));
        h.player.emit(SpeechPlaybackState.completed);
        await current;
      },
    );

    test(
      'rapid switching during native stop starts only the latest request',
      () async {
        final h = SpeechHarness(automatic: true);
        addTearDown(h.dispose);
        final stopGate = Completer<void>();
        h.player.stopGate = stopGate;
        h.player.completeImmediately = true;
        final a = h.output.play(Object(), '第一条。');
        final b = h.output.play(Object(), '第二条。');
        final finalMessage = Object();
        final c = h.output.play(finalMessage, '第三条。');
        await pumpEventQueue();
        expect(h.calls, isEmpty);
        stopGate.complete();
        await Future.wait([a, b, c]);
        expect(h.calls.single.text, '第三条。');
        expect(h.player.played, hasLength(1));
        expect(h.output.message, same(finalMessage));
      },
    );

    test(
      'cancel while native player prepares ignores late playback callbacks',
      () async {
        final h = SpeechHarness(automatic: true);
        addTearDown(h.dispose);
        final preparing = Completer<void>();
        h.player.prepareGate = preparing;
        final playback = h.output.play(Object(), '准备期间取消。');
        await pumpEventQueue();
        expect(h.player.played, hasLength(1));
        await h.output.stop();
        preparing.complete();
        await playback;
        expect(h.output.phase, SpeechOutputPhase.idle);
        expect(h.output.error, isEmpty);
        h.player.emit(SpeechPlaybackState.completed);
        await pumpEventQueue();
        expect(h.calls, hasLength(1));
        expect(h.output.phase, SpeechOutputPhase.idle);
      },
    );

    test(
      'dispose cancels pending generation and ignores late completion',
      () async {
        final h = SpeechHarness();
        final playback = h.output.play(Object(), '关闭页面。');
        await pumpEventQueue();
        await h.dispose();
        expect(h.calls.single.cancelled, isTrue);
        expect(h.player.disposed, isTrue);
        h.calls.single.result.complete(Uint8List.fromList([1]));
        await playback;
        expect(h.player.played, isEmpty);
      },
    );
  });

  group('cache and failure handling', () {
    test(
      'replay uses cache but changing voice or speed synthesizes again',
      () async {
        final h = SpeechHarness(automatic: true);
        addTearDown(h.dispose);
        h.player.completeImmediately = true;
        final message = Object();
        await h.output.play(message, '可以重新播放。');
        await h.output.play(message, '可以重新播放。');
        expect(h.calls, hasLength(1));
        expect(h.player.played, hasLength(2));
        expect(h.player.played.first, same(h.player.played.last));
        await h.output.play(message, '可以重新播放。', voice: 'ara');
        await h.output.play(message, '可以重新播放。', voice: 'ara', speed: 1.2);
        expect(h.calls, hasLength(3));
        expect(h.calls.last.voice, 'ara');
        expect(h.calls.last.speed, 1.2);
        await h.output.stop(clearCache: true);
        await h.output.play(message, '可以重新播放。');
        expect(h.calls, hasLength(4));
      },
    );

    test(
      'audio focus loss stops a long reply without starting the next segment',
      () async {
        final h = SpeechHarness(automatic: true);
        addTearDown(h.dispose);
        final playback = h.output.play(Object(), List.filled(1500, '字').join());
        await pumpEventQueue();
        expect(h.output.phase, SpeechOutputPhase.playing);
        expect(h.output.segments, 2);
        h.player.emit(SpeechPlaybackState.stopped);
        await playback;
        expect(h.output.phase, SpeechOutputPhase.idle);
        expect(h.calls, hasLength(2));
        expect(h.player.played, hasLength(1));
        h.player.emit(SpeechPlaybackState.playing);
        h.player.emit(SpeechPlaybackState.completed);
        await pumpEventQueue();
        expect(h.output.phase, SpeechOutputPhase.idle);
        expect(h.calls, hasLength(2));
      },
    );

    test(
      'bounded audio cache evicts old replies but retains the latest one',
      () async {
        final h = SpeechHarness();
        addTearDown(h.dispose);
        h.player.completeImmediately = true;
        final audio = Uint8List(SpeechOutput.cacheLimit ~/ 2 + 1);
        Future<void> generate(String text) async {
          final playback = h.output.play(Object(), text);
          await pumpEventQueue();
          h.calls.last.result.complete(audio);
          await playback;
        }

        await generate('较早的回复。');
        await generate('最新的回复。');
        expect(h.calls, hasLength(2));
        await h.output.play(Object(), '最新的回复。');
        expect(
          h.calls,
          hasLength(2),
          reason: 'latest cache entry should still exist',
        );
        await generate('较早的回复。');
        expect(
          h.calls,
          hasLength(3),
          reason: 'old reply was evicted to bound memory',
        );
      },
    );

    test(
      'decode error is reported and never retries or advances automatically',
      () async {
        final h = SpeechHarness(automatic: true);
        addTearDown(h.dispose);
        final playback = h.output.play(Object(), List.filled(1500, '字').join());
        await pumpEventQueue();
        h.player.emit(SpeechPlaybackState.error, message: '语音文件无法播放。');
        await playback;
        expect(h.output.phase, SpeechOutputPhase.failed);
        expect(h.output.error, '语音文件无法播放。');
        expect(h.calls, hasLength(2));
        expect(h.player.played, hasLength(1));
        await pumpEventQueue();
        expect(h.calls, hasLength(2));
      },
    );

    test(
      'network failure leaves retry available without playing or retrying',
      () async {
        final h = SpeechHarness();
        addTearDown(h.dispose);
        final playback = h.output.play(Object(), '这次网络失败。');
        await pumpEventQueue();
        h.calls.single.result.completeError(
          const ModelServiceException('朗读服务返回 HTTP 502。'),
        );
        await playback;
        expect(h.output.phase, SpeechOutputPhase.failed);
        expect(h.output.error, contains('HTTP 502'));
        expect(h.output.active, isFalse);
        expect(h.player.played, isEmpty);
        expect(h.calls, hasLength(1));
      },
    );

    test(
      'manual retry regenerates a decode-failed segment instead of reusing it',
      () async {
        final h = SpeechHarness(automatic: true);
        addTearDown(h.dispose);
        final message = Object();
        final first = h.output.play(message, '重新生成可播放的语音。');
        await pumpEventQueue();
        h.player.emit(SpeechPlaybackState.error, message: '语音文件无法播放。');
        await first;
        expect(
          h.calls,
          hasLength(1),
          reason: 'a failure must not retry itself',
        );
        h.player.completeImmediately = true;
        await h.output.play(message, '重新生成可播放的语音。');
        expect(
          h.calls,
          hasLength(2),
          reason: 'the failed bytes must be evicted',
        );
        expect(h.player.played, hasLength(2));
        expect(h.player.played.first, isNot(same(h.player.played.last)));
        expect(h.output.phase, SpeechOutputPhase.idle);
      },
    );

    test(
      'native preparation exception keeps its user-readable explanation',
      () async {
        final h = SpeechHarness(automatic: true);
        addTearDown(h.dispose);
        h.player.playFailure = const SpeechPlaybackException(
          '其他应用正在使用音频，请稍后点击重试朗读。',
        );
        await h.output.play(Object(), '音频焦点被占用。');
        expect(h.output.phase, SpeechOutputPhase.failed);
        expect(h.output.error, '其他应用正在使用音频，请稍后点击重试朗读。');
        expect(h.calls, hasLength(1));
      },
    );

    test(
      'foreground service failure blocks paid synthesis and native playback',
      () async {
        final h = SpeechHarness(ready: false);
        addTearDown(h.dispose);
        await h.output.play(Object(), '服务未准备好。');
        expect(h.output.phase, SpeechOutputPhase.failed);
        expect(h.output.error, contains('播放服务未能启动'));
        expect(h.calls, isEmpty);
        expect(h.player.played, isEmpty);
      },
    );
  });
}
