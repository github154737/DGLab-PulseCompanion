import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'venice_recorder.dart';
import 'venice_transcription.dart';
import 'voice_audio.dart';
import 'api_model_provider.dart';
import 'network_diagnostics.dart';

/// Nonverbal/acknowledgement-only text has no authority to change output.
/// This is a text guard, not an acoustic emotion classifier.
bool isVocalizationOnly(String text) {
  final value = text.toLowerCase().replaceAll(
    RegExp(r'[\s\p{P}\p{S}]', unicode: true),
    '',
  );
  return value.isNotEmpty &&
      (RegExp(r'^[嗯恩唔呃额哦噢喔啊呀哼哈呵诶欸唉哎]+$').hasMatch(value) ||
          RegExp(r'^(?:h+m*|m+h*|huh|uh|um|ah|oh|yeah|yes|yep|ok|okay)+$')
              .hasMatch(value));
}

class ContinuousPlaybackFailure implements Exception {
  const ContinuousPlaybackFailure(this.code, {this.recoverable = true});
  final String code;
  final bool recoverable;
}

/// Only suppress a long near-verbatim substring of the interrupted audio.
/// This does not identify a speaker or replace acoustic echo cancellation.
bool resemblesPlaybackEcho(String transcript, String playback) {
  String clean(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');
  final input = clean(transcript), output = clean(playback);
  return input.length >= 8 &&
      output.length >= 8 &&
      (output.contains(input) || input.contains(output));
}

enum ContinuousPhase {
  off,
  starting,
  listening,
  transcribing,
  replying,
  speaking,
  paused,
}

/// Lightweight energy endpoint detector, not a semantic speech classifier.
/// PCM is bounded to one utterance plus 500 ms of pre-roll, never written to disk.
class VoiceEndpoint {
  VoiceEndpoint({this.onSpeechStart});
  final VoidCallback? onSpeechStart;
  int minimumVoiceFrames = 12;
  double minimumRms = 500;
  static const frameBytes = 640; // 20 ms, PCM16 mono at 16 kHz.
  final _pre = Queue<Uint8List>();
  final _audio = BytesBuilder(copy: false);
  final _frame = Uint8List(frameBytes);
  int _offset = 0, _voice = 0, _quiet = 0, _frames = 0;
  double _noise = 100;
  bool _started = false;
  int get retainedBytes => _audio.length + _pre.length * frameBytes + _offset;

  Uint8List? add(Uint8List bytes) {
    for (final byte in bytes) {
      _frame[_offset++] = byte;
      if (_offset != frameBytes) continue;
      _offset = 0;
      final frame = Uint8List.fromList(_frame);
      final data = ByteData.sublistView(frame);
      double energy = 0;
      for (var i = 0; i < frameBytes; i += 2) {
        final value = data.getInt16(i, Endian.little);
        energy += value * value;
      }
      final rms = sqrt(energy / 320);
      final voiced = rms > max(minimumRms, _noise * 3);
      if (!_started) {
        _pre.add(frame);
        if (_pre.length > 25) _pre.removeFirst();
        _voice = voiced ? _voice + 1 : 0;
        if (!voiced) _noise = _noise * .97 + min(rms, 2000) * .03;
        if (_voice < minimumVoiceFrames) continue;
        _started = true;
        onSpeechStart?.call();
        for (final part in _pre) {
          _audio.add(part);
        }
        _pre.clear();
      } else {
        _audio.add(frame);
      }
      _frames++;
      _quiet = voiced ? 0 : _quiet + 1;
      if (_quiet >= 40 || _frames >= 1000) {
        final result = _audio.takeBytes();
        reset();
        return result;
      }
    }
    return null;
  }

  void reset() {
    _pre.clear();
    _audio.clear();
    _offset = _voice = _quiet = _frames = 0;
    _noise = 100;
    _started = false;
  }
}

class ContinuousVoice extends ChangeNotifier {
  ContinuousVoice({
    required this.capture,
    required this.prepare,
    required this.transcribe,
    required this.reply,
    required this.cancelWork,
    this.interruptReply,
    this.echoDelay = const Duration(milliseconds: 350),
    this.noSpeechDelay = const Duration(milliseconds: 500),
  });
  final SpeechCapture capture;
  final Future<bool> Function() prepare;
  final Future<String> Function(Uint8List) transcribe;
  final Future<void> Function(String) reply;
  final Future<void> Function() cancelWork;
  final Future<void> Function()? interruptReply;
  // Enabled explicitly by the UI after explaining microphone use during speech.
  bool bargeIn = false;
  final Duration echoDelay;
  final Duration noSpeechDelay;
  int _emptyCount = 0, _playbackFailures = 0;
  NetworkTrace? _trace;
  String _recoveryNotice = '';

  Future<String> _transcribe(Uint8List pcm) async {
    _trace?.mark('片段提交 · ${pcm.length ~/ 32}ms · ${pcm.length} 字节');
    try {
      final text = (await transcribe(pcmToWav(pcm))).trim();
      if (text.isNotEmpty) {
        _emptyCount = 0;
        _trace?.mark(
          '转写完成 · ${text.runes.length} 字 · 短应答 ${isVocalizationOnly(text)}',
        );
      }
      return text;
    } on NoSpeechDetected {
      return '';
    }
  }

  Future<void> _noSpeech() async {
    _emptyCount++;
    _recoveryNotice = '没有识别到文字，仍在听';
    _trace?.mark(
      '空转写 $_emptyCount 次 · 跳过聊天和控制 · 冷却 ${noSpeechDelay.inMilliseconds}ms',
    );
    _set(ContinuousPhase.starting, '没有识别到文字，仍在听');
    await Future<void>.delayed(noSpeechDelay);
  }

  Future<void> _reply(String text) async {
    _recoveryNotice = '';
    try {
      await reply(text);
      _playbackFailures = 0;
    } on ContinuousPlaybackFailure catch (error) {
      _playbackFailures++;
      _trace?.mark('朗读失败 · ${error.code} · 连续 $_playbackFailures 次 · 不重播');
      if (!error.recoverable || _playbackFailures >= 3) rethrow;
      _recoveryNotice = '本段朗读失败，文字已保留；仍可继续说话。';
    }
  }

  String _failureNotice(Object error) {
    // Do not put raw exceptions/provider responses into diagnostics.
    _trace?.mark(
      '暂停类别 ${error is ModelServiceException
          ? error.code
          : error is ContinuousPlaybackFailure
          ? "speech_failure"
          : error is VoiceAudioFailure
          ? error.code
          : "conversation_failure"}',
    );
    if (error is VoiceAudioFailure) return error.message;
    if (error is ContinuousPlaybackFailure) {
      return '朗读服务连续失败或暂不可用，已暂停；请查看连接诊断后继续。不会自动重播。';
    }
    if (error is ModelServiceException) return '${error.message} 已暂停，不会自动重发。';
    return '本轮已暂停，请检查麦克风或网络后点击继续；不会自动重发。';
  }

  ContinuousPhase phase = ContinuousPhase.off;
  String notice = '';
  bool allowBackground = false;
  bool get enabled => phase != ContinuousPhase.off;
  bool get running => enabled && phase != ContinuousPhase.paused;
  final detector = VoiceEndpoint();
  StreamSubscription<Uint8List>? _subscription;
  Timer? _watchdog;
  DateTime _lastFrame = DateTime.now();
  int _epoch = 0;
  bool _dead = false;
  Future<void> _closing = Future.value();
  Future<void>? _opening;
  Completer<void>? _cancelListen;

  void _set(ContinuousPhase value, [String message = '']) {
    if (_dead) return;
    _trace?.mark('状态 ${phase.name} → ${value.name} · 轮次 $_epoch');
    phase = value;
    notice = message;
    notifyListeners();
  }

  void speaking() {
    if (phase == ContinuousPhase.replying) {
      _set(ContinuousPhase.speaking);
    }
  }

  Future<void> start() async {
    if (_dead || running) return;
    final epoch = ++_epoch;
    _trace = NetworkTrace('持续对话');
    _trace!.mark('开启 · 开口打断 $bargeIn · 后台 $allowBackground');
    _emptyCount = _playbackFailures = 0;
    _set(ContinuousPhase.starting);
    await _closing;
    if (_dead || epoch != _epoch) return;
    unawaited(bargeIn ? _duplexLoop(epoch) : _loop(epoch));
  }

  /// One capture stream stays open across turns. PCM is discarded during STT;
  /// playback/listening PCM is bounded by the endpoint detector. Turn tickets
  /// invalidate old network completions without losing the interrupting phrase.
  Future<void> _duplexLoop(int epoch) async {
    bool valid() => !_dead && epoch == _epoch && running;
    var turn = 0;
    Future<void> interruption = Future.value();
    final ended = Completer<void>();
    _cancelListen = ended;
    late final VoiceEndpoint endpoint;
    endpoint = VoiceEndpoint(
      onSpeechStart: () {
        if (!valid()) return;
        _trace?.mark(
          '检测到连续声音 · 阈值 ${endpoint.minimumRms} · 帧数 ${endpoint.minimumVoiceFrames}',
        );
        if (phase == ContinuousPhase.replying ||
            phase == ContinuousPhase.speaking) {
          ++turn;
          // Invoke cancellation synchronously before accepting another turn.
          interruption = (interruptReply ?? cancelWork)().catchError((
            Object _,
          ) {
            if (valid()) unawaited(pause('打断未完成，已暂停；请点击继续。'));
          });
          _set(ContinuousPhase.listening, '已打断，继续说…');
        }
      },
    );
    Future<void> process(Uint8List pcm, int ticket) async {
      bool current() => valid() && ticket == turn;
      try {
        await interruption;
        if (!current()) return;
        final text = await _transcribe(pcm);
        if (!current()) return;
        if (text.isEmpty) {
          await _noSpeech();
          if (!current()) return;
          endpoint.reset();
          _set(ContinuousPhase.listening, '没有识别到文字，仍在听');
          return;
        }
        _set(ContinuousPhase.replying);
        await _reply(text);
        if (!current()) return;
        // Drain the acoustic tail before returning to the normal sensitivity.
        _set(ContinuousPhase.starting);
        await Future<void>.delayed(echoDelay);
        if (!current()) return;
        endpoint.reset();
        _set(ContinuousPhase.listening, _recoveryNotice);
      } catch (error) {
        if (current()) unawaited(pause(_failureNotice(error)));
      }
    }

    try {
      Stream<Uint8List>? stream;
      _opening = () async {
        stream = await capture.start();
      }();
      await _opening;
      _opening = null;
      if (!valid()) return;
      if (!await prepare()) throw StateError('foreground_unavailable');
      if (!valid()) return;
      _set(ContinuousPhase.listening);
      _lastFrame = DateTime.now();
      void failed() {
        if (valid()) unawaited(pause('麦克风被中断，已暂停；返回前台后点击继续。'));
      }

      _subscription = stream!.listen(
        (part) {
          if (!valid()) return;
          _lastFrame = DateTime.now();
          if (phase != ContinuousPhase.listening &&
              phase != ContinuousPhase.replying &&
              phase != ContinuousPhase.speaking) {
            endpoint.reset();
            return;
          }
          final replying = phase != ContinuousPhase.listening;
          endpoint.minimumRms = replying ? 1100 : 500;
          endpoint.minimumVoiceFrames = replying ? 18 : 12;
          final pcm = endpoint.add(part);
          if (pcm != null) {
            final ticket = ++turn;
            _set(ContinuousPhase.transcribing);
            unawaited(process(pcm, ticket));
          }
        },
        onError: (Object _) => failed(),
        onDone: failed,
      );
      _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        if (DateTime.now().difference(_lastFrame) >
            const Duration(seconds: 4)) {
          failed();
        }
      });
      await ended.future;
    } catch (error) {
      if (valid()) {
        await pause(
          error is VoiceAudioFailure
              ? error.message
              : '无法开启连续语音，请检查麦克风和通知权限后继续。',
        );
      }
    } finally {
      endpoint.reset();
    }
  }

  Future<void> _loop(int epoch) async {
    bool valid() => !_dead && epoch == _epoch && running;
    try {
      while (valid()) {
        detector.reset();
        final segment = Completer<Uint8List?>();
        final interrupted = Completer<void>();
        _cancelListen = interrupted;
        Stream<Uint8List>? stream;
        _opening = () async {
          stream = await capture.start();
        }();
        await _opening;
        _opening = null;
        if (!valid()) {
          return; // The cancelling owner closes the pending capture.
        }
        // Permission is acquired by capture.start, before starting the mic FGS.
        if (!await prepare()) throw StateError('foreground_unavailable');
        if (!valid()) return;
        _set(ContinuousPhase.listening, _recoveryNotice);
        _lastFrame = DateTime.now();
        void failed() {
          if (!segment.isCompleted) {
            segment.completeError(StateError('capture_interrupted'));
          }
        }

        _subscription = stream!.listen(
          (part) {
            if (!valid() || segment.isCompleted) return;
            _lastFrame = DateTime.now();
            final pcm = detector.add(part);
            if (pcm != null) segment.complete(pcm);
          },
          onError: (Object _) => failed(),
          onDone: failed,
        );
        _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
          if (DateTime.now().difference(_lastFrame) >
              const Duration(seconds: 4)) {
            failed();
          }
        });
        final pcm = await Future.any<Uint8List?>([
          segment.future,
          interrupted.future.then((_) => null),
        ]);
        if (!valid()) return;
        await _closeCapture();
        if (!valid() || pcm == null) return;
        _set(ContinuousPhase.transcribing);
        final text = await _transcribe(pcm);
        if (!valid()) return;
        if (text.isEmpty) {
          await _noSpeech();
          continue;
        }
        _set(ContinuousPhase.replying);
        await _reply(text);
        if (!valid()) return;
        // Do not immediately recapture the speaker's acoustic tail.
        await Future<void>.delayed(echoDelay);
      }
    } catch (error) {
      if (valid()) {
        await pause(
          error is VoiceAudioFailure
              ? error.message
              : error is StateError && error.message == 'foreground_unavailable'
              ? '连续语音服务未启动，请允许麦克风和通知权限，返回前台后点击继续。'
              : _failureNotice(error),
        );
      }
    }
  }

  Future<void> _closeCapture() async {
    _watchdog?.cancel();
    _watchdog = null;
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } finally {
      try {
        await capture.stop();
      } finally {
        detector.reset();
      }
    }
  }

  Future<void> pause([String reason = '麦克风已静音，点击继续后重新监听。']) =>
      _stop(false, reason);
  Future<void> end() => _stop(true, '');

  Future<void> _stop(bool end, String message) {
    ++_epoch;
    _set(end ? ContinuousPhase.off : ContinuousPhase.paused, message);
    if (_cancelListen?.isCompleted == false) _cancelListen!.complete();
    final opening = _opening;
    final previous = _closing;
    // Queue cleanup so a late permission result cannot stop a newer capture.
    return _closing = () async {
      await previous;
      final cancelled = cancelWork().catchError((_) {});
      try {
        await opening;
      } catch (_) {}
      try {
        await _closeCapture();
      } catch (_) {}
      await cancelled;
    }();
  }

  @override
  void dispose() {
    _dead = true;
    unawaited(end());
    super.dispose();
  }
}
