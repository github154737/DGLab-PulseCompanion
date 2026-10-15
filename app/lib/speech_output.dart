import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_model_provider.dart';
import 'speech_audio_player.dart';
import 'venice_tts.dart';
import 'progressive_audio.dart';
import 'network_diagnostics.dart';

enum SpeechOutputPhase { idle, generating, playing, failed }

/// Output only: no chat requests, prompts or device commands live here.
class SpeechOutput extends ChangeNotifier {
  SpeechOutput({
    required this.createClient,
    required this.player,
    required this.preparePlayback,
  }) {
    _events = player.events.listen(_onEvent);
  }

  final VeniceTtsClient Function() createClient;
  final SpeechAudioPlayer player;
  final Future<bool> Function() preparePlayback;
  void Function()? onInterrupted;
  late final StreamSubscription<SpeechPlaybackEvent> _events;
  VeniceTtsClient? _client;
  VeniceTtsClient? _prefetchClient;
  Completer<void>? _finished;
  int _epoch = 0;
  ProgressiveAudio? _audioSource, _prefetchSource;
  Completer<void>? _inputCancelled;
  bool _disposed = false;
  Future<void> _stopping = Future.value();
  final _cache = <String, Uint8List>{};
  static const cacheLimit = 12 * 1024 * 1024;
  int _cacheBytes = 0;
  Object? message;
  SpeechOutputPhase phase = SpeechOutputPhase.idle;
  String error = '';
  String failureCode = '';
  Duration position = Duration.zero, duration = Duration.zero;
  int segment = 0, segments = 0;
  String currentText = '';
  bool get active =>
      phase == SpeechOutputPhase.generating ||
      phase == SpeechOutputPhase.playing;

  /// Read the conversational text, never hidden machine blocks or code fences.
  static String spokenText(String source) =>
      _withoutTechnicalNotes(source)
          .replaceAll(RegExp(r'\[\[CTRL\b.*?(?:\]\]|$)', dotAll: true), '')
          .replaceAll(RegExp(r'```.*?(?:```|$)', dotAll: true), '')
          .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
          .replaceAll(RegExp(r'https?://\S+'), '')
          .replaceAll(RegExp(r'[*_`#]'), '')
          .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
          .trim();

  static String _withoutTechnicalNotes(String source) {
    bool technical(String value) =>
        RegExp(r'模拟(?:调整|执行|状态|输出)|(?:实际|真实|实物)设备|执行回执|控制接口').hasMatch(value);
    final parenthesized = source.replaceAllMapped(
      RegExp(r'[（(]\s*(?:注|备注|说明)[：:]([^）)]*)(?:[）)]|$)'),
      (match) => technical(match[1]!) ? '' : match[0]!,
    );
    return parenthesized.replaceAllMapped(
      RegExp(r'^\s*(?:注|备注|说明)[：:][^\n]*', multiLine: true),
      (match) => technical(match[0]!) ? '' : match[0]!,
    );
  }

  static List<String> splitText(String text) {
    final runes = text.runes.toList();
    if (runes.length > 12000) {
      throw const ModelServiceException('这条回复过长，暂不支持朗读；文字已保留。');
    }
    final parts = <String>[];
    var start = 0;
    while (start < runes.length) {
      var end = (start + 1000).clamp(0, runes.length);
      if (end < runes.length) {
        for (var i = end - 1; i > start + 500; i--) {
          if ('。！？!?；;\n'.runes.contains(runes[i])) {
            end = i + 1;
            break;
          }
        }
      }
      final part = String.fromCharCodes(runes.sublist(start, end)).trim();
      if (part.isNotEmpty) parts.add(part);
      start = end;
    }
    return parts;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onEvent(SpeechPlaybackEvent event) {
    if (_disposed || _finished == null) return;
    switch (event.state) {
      case SpeechPlaybackState.playing:
        if (phase != SpeechOutputPhase.playing) {
          NetworkTrace('播放').mark('播放器已开始播放');
        }
        phase = SpeechOutputPhase.playing;
        position = event.position;
        duration = event.duration;
        _notify();
      case SpeechPlaybackState.completed:
        if (!_finished!.isCompleted) _finished!.complete();
      case SpeechPlaybackState.stopped:
        // Audio focus loss and unplugging must not cause automatic resumption.
        onInterrupted?.call();
        unawaited(stop());
      case SpeechPlaybackState.error:
        if (!_finished!.isCompleted) {
          _finished!.completeError(
            ModelServiceException(
              event.message ?? '播放失败，请重试。',
              code: 'playback_device',
            ),
          );
        }
    }
  }

  Future<void> play(
    Object messageId,
    String text, {
    String voice = 'eve',
    double speed = 1,
    Stream<String>? sentences,
  }) async {
    if (_disposed) return;
    final stopped = _cancelCurrent(notify: false);
    final current = _epoch;
    message = messageId;
    error = '';
    failureCode = '';
    final trace = NetworkTrace('朗读队列');
    trace.mark('开始 · 流式 ${sentences != null} · 原文 ${text.runes.length} 字');
    position = duration = Duration.zero;
    segment = segments = 0;
    // Publish replacement work before awaiting native stop. Otherwise the chat
    // request's finally block can drop Android's foreground service while the
    // new speech is already scheduled, making a background restart impossible.
    phase = SpeechOutputPhase.generating;
    _notify();
    var failed = false;
    bool valid() => !_disposed && current == _epoch && !failed;
    String? playingCacheKey;
    StreamIterator<String>? iterator;
    final inputCancelled = Completer<void>();
    _inputCancelled = inputCancelled;
    try {
      await stopped;
      if (!valid()) return;
      final chunks = sentences == null
          ? splitText(spokenText(text))
          : <String>[];
      if (sentences == null && chunks.isEmpty) {
        throw const ModelServiceException('这条回复没有可朗读的文字。');
      }
      segments = chunks.length;
      iterator = StreamIterator(sentences ?? Stream.fromIterable(chunks));
      segment = 0;
      if (!await preparePlayback()) {
        throw const ModelServiceException('语音播放服务未能启动，请返回前台重试。');
      }
      if (!valid()) return;
      Future<_PreparedSpeech?> readNext({bool prefetch = false}) async {
        try {
          while (await Future.any<bool>([
            iterator!.moveNext(),
            inputCancelled.future.then((_) => false),
          ])) {
            if (!valid()) return null;
            final raw = iterator!.current;
            final text = spokenText(raw);
            trace.mark(
              '文本过滤 · 输入 ${raw.runes.length} 字 · 输出 ${text.runes.length} 字 · 预取 $prefetch',
            );
            if (text.isEmpty) continue;
            if (!prefetch) return _PreparedSpeech(text);
            final cached = _cache['$voice/$speed/$text'];
            if (cached != null) return _PreparedSpeech(text, audio: cached);
            final client = createClient();
            _prefetchClient = client;
            ProgressiveAudio? source;
            final ready = Completer<void>();
            if (player is ProgressiveSpeechPlayer) {
              source = await ProgressiveAudio.open();
              if (!valid()) {
                await source.close();
                return null;
              }
              _prefetchSource = source;
              client.onAudioChunk = (bytes) async {
                if (!valid()) return;
                source!.add(bytes);
                if (!ready.isCompleted) ready.complete();
              };
            }
            // Capture errors immediately, even while the previous clip plays.
            // A progressive next segment need not wait for its entire download.
            final pending = client
                .synthesize(text, voice: voice, speed: speed)
                .then<_AudioResult>(
                  (bytes) {
                    source?.finish();
                    if (!ready.isCompleted) ready.complete();
                    return _AudioResult(bytes: bytes);
                  },
                  onError: (Object error) {
                    source?.finish();
                    if (!ready.isCompleted) ready.complete();
                    return _AudioResult(error: error);
                  },
                );
            return _PreparedSpeech(
              text,
              pending: pending,
              source: source,
              ready: ready.future,
              client: client,
            );
          }
          return null;
        } catch (error) {
          // Report next-segment failure only after the current speech ends.
          return valid() ? _PreparedSpeech('', error: error) : null;
        }
      }

      Future<_PreparedSpeech?>? next;
      while (valid()) {
        final prepared = await (next ?? readNext());
        next = null;
        if (!valid() || prepared == null) break;
        playingCacheKey = null;
        if (prepared.error != null) throw prepared.error!;
        final chunk = prepared.text;
        currentText = chunk;
        segment++;
        trace.mark('片段 $segment · ${chunk.runes.length} 字');
        position = duration = Duration.zero;
        phase = SpeechOutputPhase.generating;
        _notify();
        final cacheKey = '$voice/$speed/$chunk';
        var bytes = _cache.remove(cacheKey);
        final done = Completer<void>();
        _finished = done;
        final outcome = done.future.then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );
        Future<Object?>? preparing;
        ProgressiveAudio? source;
        if (bytes != null) {
          _cache[cacheKey] = bytes;
        } else if (prepared.audio != null) {
          bytes = prepared.audio!;
          _remember(cacheKey, bytes);
        } else if (prepared.pending != null) {
          source = prepared.source;
          _audioSource = source;
          _prefetchSource = null;
          _client = prepared.client;
          _prefetchClient = null;
          if (source != null) {
            await Future.any<void>([prepared.ready!, inputCancelled.future]);
            if (!valid()) return;
            preparing = (player as ProgressiveSpeechPlayer)
                .playUrl(source.uri)
                .then<Object?>((_) => null, onError: (Object e) => e);
          }
          final result = await Future.any<_AudioResult>([
            prepared.pending!,
            inputCancelled.future.then((_) => _AudioResult()),
          ]);
          if (!valid()) return;
          if (result.error != null) throw result.error!;
          bytes = result.bytes!;
          _client = null;
          _remember(cacheKey, bytes);
        } else {
          final client = createClient();
          _client = client;
          if (player is ProgressiveSpeechPlayer) {
            source = await ProgressiveAudio.open();
            if (!valid()) {
              await source.close();
              return;
            }
            _audioSource = source;
            client.onAudioChunk = (part) async {
              if (!valid()) return;
              source!.add(part);
              preparing ??= (player as ProgressiveSpeechPlayer)
                  .playUrl(source.uri)
                  .then<Object?>((_) => null, onError: (Object e) => e);
            };
          }
          bytes = await client.synthesize(chunk, voice: voice, speed: speed);
          if (!valid()) return;
          _client = null;
          source?.finish();
          _remember(cacheKey, bytes);
        }
        if (!valid()) return;
        playingCacheKey = cacheKey;
        if (preparing == null) {
          await player.play(bytes);
        } else {
          final error = await preparing!.timeout(const Duration(seconds: 65));
          if (error != null) throw error;
        }
        if (!valid()) return;
        next = readNext(prefetch: true);
        final result = await outcome.timeout(const Duration(minutes: 15));
        if (!valid()) return;
        _finished = null;
        await source?.close();
        if (identical(_audioSource, source)) _audioSource = null;
        if (result != null) throw result;
      }
      if (valid()) {
        phase = SpeechOutputPhase.idle;
        position = duration;
        _notify();
      }
    } catch (e) {
      if (!valid()) return;
      failureCode = e is ModelServiceException
          ? e.code
          : e is SpeechPlaybackException
          ? 'playback_device'
          : 'speech_unknown';
      trace.mark('失败 · 片段 $segment · 类别 $failureCode · 不自动重播');
      failed = true;
      // A valid MP3 header does not guarantee the platform can decode it.
      // Manual retry must regenerate a failed segment, not loop a bad cache.
      if (playingCacheKey != null) {
        final failedBytes = _cache.remove(playingCacheKey);
        if (failedBytes != null) _cacheBytes -= failedBytes.length;
      }
      _client?.cancel();
      _client = null;
      _prefetchClient?.cancel();
      _prefetchClient = null;
      final prefetchedSource = _prefetchSource;
      _prefetchSource = null;
      if (prefetchedSource != null) unawaited(prefetchedSource.close());
      if (!inputCancelled.isCompleted) inputCancelled.complete();
      _finished = null;
      final failedSource = _audioSource;
      _audioSource = null;
      await _stopPlayer();
      await failedSource?.close();
      if (_disposed || current != _epoch) return;
      phase = SpeechOutputPhase.failed;
      error = switch (e) {
        ModelServiceException() => e.message,
        SpeechPlaybackException() => e.message,
        _ => '语音未能播放，文字已保留，可点击重试。',
      };
      _notify();
    } finally {
      if (iterator != null) unawaited(iterator.cancel());
      if (identical(_inputCancelled, inputCancelled)) _inputCancelled = null;
    }
  }

  void _remember(String key, Uint8List bytes) {
    if (bytes.length > cacheLimit) return;
    final old = _cache.remove(key);
    if (old != null) _cacheBytes -= old.length;
    while (_cacheBytes + bytes.length > cacheLimit && _cache.isNotEmpty) {
      _cacheBytes -= _cache.remove(_cache.keys.first)!.length;
    }
    _cache[key] = bytes;
    _cacheBytes += bytes.length;
  }

  Future<void> _stopPlayer() {
    _stopping = _stopping.then((_) => player.stop()).catchError((_) {});
    return _stopping;
  }

  Future<void> stop({bool clearCache = false}) =>
      _cancelCurrent(notify: true, clearCache: clearCache);

  Future<void> _cancelCurrent({required bool notify, bool clearCache = false}) {
    _epoch++;
    final waiting = _inputCancelled;
    _inputCancelled = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    final source = _audioSource;
    _audioSource = null;
    if (source != null) unawaited(source.close());
    _client?.cancel();
    _client = null;
    _prefetchClient?.cancel();
    _prefetchClient = null;
    final prefetchedSource = _prefetchSource;
    _prefetchSource = null;
    if (prefetchedSource != null) unawaited(prefetchedSource.close());
    final done = _finished;
    _finished = null;
    if (done != null && !done.isCompleted) done.complete();
    phase = SpeechOutputPhase.idle;
    error = '';
    if (clearCache) {
      _cache.clear();
      _cacheBytes = 0;
      message = null;
      position = duration = Duration.zero;
    }
    if (notify) _notify();
    return _stopPlayer();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(stop(clearCache: true));
    unawaited(_events.cancel());
    unawaited(_stopping.then((_) => player.dispose()).catchError((_) {}));
    super.dispose();
  }
}

class _PreparedSpeech {
  _PreparedSpeech(
    this.text, {
    this.audio,
    this.error,
    this.pending,
    this.source,
    this.ready,
    this.client,
  });
  final String text;
  final Uint8List? audio;
  final Object? error;
  final Future<_AudioResult>? pending;
  final ProgressiveAudio? source;
  final Future<void>? ready;
  final VeniceTtsClient? client;
}

class _AudioResult {
  _AudioResult({this.bytes, this.error});
  final Uint8List? bytes;
  final Object? error;
}
