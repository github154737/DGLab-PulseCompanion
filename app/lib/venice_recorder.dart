import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'voice_audio.dart';
import 'venice_transcription.dart';

abstract class SpeechCapture {
  Future<Stream<Uint8List>> start();
  Future<void> stop();
}

class NativeSpeechCapture implements SpeechCapture {
  bool duplex = false;
  AudioRecorder? _recorder;
  @override
  Future<Stream<Uint8List>> start() async {
    final recorder = AudioRecorder();
    _recorder = recorder;
    try {
      if (!await recorder.hasPermission()) {
        throw const VoiceAudioFailure('permission_denied', 'permission');
      }
      var speaker = false;
      if (duplex && defaultTargetPlatform == TargetPlatform.android) {
        final config = await const MethodChannel('aihaptics/speech')
            .invokeMapMethod<String, dynamic>('duplexCapture');
        if (config?['supported'] != true) {
          throw const VoiceAudioFailure('echo_unavailable', 'capture');
        }
        speaker = config?['speaker'] == true;
      }
      return await recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: false,
          streamBufferSize: 640,
          // Playback owns audio focus. The recorder must not pause our player
          // (or itself) when the other half of the same conversation starts.
          audioInterruption: duplex
              ? AudioInterruptionMode.none
              : AudioInterruptionMode.pause,
          androidConfig: duplex
              ? AndroidRecordConfig(
                  audioSource: AndroidAudioSource.voiceCommunication,
                  audioManagerMode: AudioManagerMode.modeInCommunication,
                  speakerphone: speaker,
                )
              : const AndroidRecordConfig(),
        ),
      );
    } catch (error) {
      try {
        await stop();
      } catch (_) {}
      throw VoiceAudioFailure.from(error, 'capture');
    }
  }

  @override
  Future<void> stop() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        await recorder.stop();
      } finally {
        await recorder.dispose();
        if (duplex && defaultTargetPlatform == TargetPlatform.android) {
          await const MethodChannel('aihaptics/speech')
              .invokeMethod<void>('endDuplexCapture');
        }
      }
    }
  }
}

enum RecordingPhase { idle, starting, recording, stopping, ready, failed }

/// A bounded memory-only recording, with no upload or playback responsibilities.
class VeniceRecorder extends ChangeNotifier {
  VeniceRecorder({
    SpeechCapture? capture,
    this.maxDuration = const Duration(seconds: 60),
  }) : capture = capture ?? NativeSpeechCapture();
  final SpeechCapture capture;
  final Duration maxDuration;
  RecordingPhase phase = RecordingPhase.idle;
  String error = '';
  final _pcm = BytesBuilder();
  StreamSubscription<Uint8List>? _subscription;
  Timer? _timer;
  Future<void>? _opening;
  Future<void>? _finishing;
  bool _dead = false;
  int _epoch = 0;
  int get byteCount => _pcm.length;
  double get seconds => byteCount / 32000;
  bool get capturing => phase == RecordingPhase.recording;
  bool get busy => [
    RecordingPhase.starting,
    RecordingPhase.recording,
    RecordingPhase.stopping,
  ].contains(phase);
  void changed() {
    if (!_dead) notifyListeners();
  }

  Future<void> start() {
    if (_dead || busy) return Future.value();
    return _opening = _start();
  }

  Future<void> _start() async {
    final epoch = ++_epoch;
    _pcm.clear();
    error = '';
    phase = RecordingPhase.starting;
    changed();
    try {
      final stream = await capture.start();
      if (_dead || epoch != _epoch) {
        await capture.stop();
        return;
      }
      phase = RecordingPhase.recording;
      _subscription = stream.listen(
        (part) {
          if (_dead || epoch != _epoch || !capturing) return;
          final available = 1920000 - _pcm.length;
          _pcm.add(part.length > available ? part.sublist(0, available) : part);
          changed();
          if (_pcm.length >= 1920000) unawaited(stop());
        },
        onError: (Object e) {
          if (!_dead && epoch == _epoch && capturing) {
            error = VoiceAudioFailure.from(e, 'capture').message;
            unawaited(stop());
          }
        },
        onDone: () {
          if (!_dead && epoch == _epoch && capturing) {
            error = const VoiceAudioFailure('capture_ended', 'capture').message;
            unawaited(stop());
          }
        },
      );
      _timer = Timer(maxDuration, () => unawaited(stop()));
      changed();
    } catch (e) {
      if (_dead || epoch != _epoch) return;
      error = VoiceAudioFailure.from(e, 'capture').message;
      phase = RecordingPhase.failed;
      changed();
    }
  }

  Future<void> stop() {
    if (phase == RecordingPhase.stopping) return _finishing ?? Future.value();
    if (_dead || !busy) return Future.value();
    return _finishing = _stop();
  }

  Future<void> _stop() async {
    ++_epoch;
    phase = RecordingPhase.stopping;
    _timer?.cancel();
    changed();
    try {
      await _opening;
      await _subscription?.cancel();
      _subscription = null;
      await capture.stop();
    } catch (_) {
      error = '麦克风停止失败，请检查输入设备后重试。';
    }
    if (_dead) return;
    if (error.isNotEmpty || _pcm.length < 3200) {
      if (error.isEmpty) error = '录音太短或没有采集到声音，请重新录音。';
      _pcm.clear();
      phase = RecordingPhase.failed;
    } else {
      phase = RecordingPhase.ready;
    }
    changed();
  }

  Uint8List wav() {
    if (phase != RecordingPhase.ready) throw StateError('recording_not_ready');
    final bytes = _pcm.toBytes();
    return pcmToWav(
      bytes.length.isOdd
          ? Uint8List.sublistView(bytes, 0, bytes.length - 1)
          : bytes,
    );
  }

  Future<void> discard() async {
    await stop();
    _pcm.clear();
    error = '';
    if (!_dead) {
      phase = RecordingPhase.idle;
      changed();
    }
  }

  @override
  void dispose() {
    _dead = true;
    ++_epoch;
    _timer?.cancel();
    _pcm.clear();
    unawaited(_cleanup());
    super.dispose();
  }

  Future<void> _cleanup() async {
    try {
      await _opening;
      await _finishing;
      await _subscription?.cancel();
      await capture.stop();
    } catch (_) {}
  }
}
