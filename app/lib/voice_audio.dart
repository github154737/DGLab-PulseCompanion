import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:record/record.dart';

abstract class VoiceAudio {
  Future<Stream<Uint8List>> capture();
  Future<void> feed(Uint8List bytes);
  Future<void> stopPlayback();
  Future<int> pending();
  Future<void> stopCapture();
  Future<void> dispose();
}

class VoiceAudioFailure implements Exception {
  const VoiceAudioFailure(this.code, this.stage);
  final String code, stage;
  factory VoiceAudioFailure.from(Object error, String stage) {
    if (error is VoiceAudioFailure) return error;
    if (error is MissingPluginException) {
      return VoiceAudioFailure('component_missing', stage);
    }
    return VoiceAudioFailure(
      stage == 'playback' ? 'playback_unavailable' : 'capture_unavailable',
      stage,
    );
  }
  String get message => switch (code) {
    'echo_unavailable' => '此手机未报告回声消除支持。请连接耳机，或结束后重新开启连续对话并关闭“开口打断”。',
    'component_missing' => '此安装包的音频组件未加载，请使用新版完整安装目录启动。无需修改 API Key。',
    'permission_denied' => '系统未允许使用麦克风，请在系统隐私设置中允许此应用访问麦克风后重试。',
    'playback_unavailable' => '无法打开播放设备，请检查默认扬声器或耳机后重试。',
    'capture_ended' => '麦克风采集中断，请检查输入设备连接后重试。',
    _ => '无法打开麦克风，请检查默认输入设备、系统麦克风权限及设备占用后重试。',
  };
  Map<String, String> get diagnostic => {'code': code, 'stage': stage};
}

class NativeVoiceAudio implements VoiceAudio {
  static const channel = MethodChannel('aihaptics/pcm');
  AudioRecorder? _recorder;
  final Queue<_AudioChunk> _queue = Queue();
  Timer? _pump;
  int _epoch = 0, _queued = 0, _capacity = 0;
  bool _draining = false;
  bool _setup = false;
  @override
  Future<Stream<Uint8List>> capture() async {
    final recorder = AudioRecorder();
    _recorder = recorder;
    var stage = 'permission';
    try {
      if (!await recorder.hasPermission()) {
        throw const VoiceAudioFailure('permission_denied', 'permission');
      }
      stage = 'playback';
      await initializePlayback();
      stage = 'capture';
      return await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: false,
        ),
      );
    } catch (error) {
      if (identical(_recorder, recorder)) _recorder = null;
      // Cleanup failure must not replace the original capture error.
      try {
        await recorder.dispose();
      } catch (_) {}
      throw VoiceAudioFailure.from(error, stage);
    }
  }

  Future<void> initializePlayback() async {
    if (_setup) return;
    await channel.invokeMethod<void>('setup');
    _capacity = await channel.invokeMethod<int>('capacity') ?? 0;
    if (_capacity < 240) throw StateError('audio_capacity');
    _setup = true;
  }

  @override
  Future<void> feed(Uint8List bytes) {
    if (!_setup ||
        bytes.isEmpty ||
        bytes.length.isOdd ||
        bytes.length > 48000 ||
        _queued + bytes.length > 576000) {
      return Future.error(StateError('audio_backpressure'));
    }
    _queued += bytes.length;
    final chunk = _AudioChunk(bytes);
    _queue.add(chunk);
    _pump ??= Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => unawaited(_drain()),
    );
    unawaited(_drain());
    return chunk.done.future;
  }

  Future<void> _drain() async {
    if (_draining || _queue.isEmpty) return;
    _draining = true;
    final epoch = _epoch;
    try {
      final pending = await channel.invokeMethod<int>('pending') ?? 0;
      if (epoch != _epoch || _queue.isEmpty) return;
      final free = math.min(_capacity, 12000) - pending;
      if (free < 240) return;
      final chunk = _queue.first;
      final count = math.min(
        math.min(free * 2, 4800),
        chunk.bytes.length - chunk.offset,
      );
      await channel.invokeMethod<void>(
        'feed',
        Uint8List.sublistView(chunk.bytes, chunk.offset, chunk.offset + count),
      );
      if (epoch != _epoch) return;
      chunk.offset += count;
      _queued -= count;
      if (chunk.offset == chunk.bytes.length) {
        _queue.removeFirst();
        chunk.done.complete();
      }
      if (_queue.isEmpty) {
        _pump?.cancel();
        _pump = null;
      }
    } catch (_) {
      if (epoch == _epoch) {
        final failed = _queue.toList();
        _queue.clear();
        _queued = 0;
        _pump?.cancel();
        _pump = null;
        for (final chunk in failed) {
          chunk.done.completeError(StateError('audio_output_error'));
        }
      }
    } finally {
      _draining = false;
    }
  }

  @override
  Future<void> stopPlayback() async {
    _epoch++;
    _pump?.cancel();
    _pump = null;
    for (final chunk in _queue) {
      chunk.done.complete();
    }
    _queue.clear();
    _queued = 0;
    if (_setup) await channel.invokeMethod<void>('stop');
  }

  @override
  Future<int> pending() async => _setup
      ? (await channel.invokeMethod<int>('pending') ?? 0) + _queued ~/ 2
      : 0;
  @override
  Future<void> stopCapture() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        await recorder.stop();
      } finally {
        await recorder.dispose();
      }
    }
  }

  @override
  Future<void> dispose() async {
    await stopCapture();
    await stopPlayback();
  }
}

class _AudioChunk {
  _AudioChunk(this.bytes);
  final Uint8List bytes;
  final Completer<void> done = Completer<void>();
  int offset = 0;
}
