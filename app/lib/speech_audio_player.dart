import 'network_diagnostics.dart';

import 'dart:async';

import 'package:flutter/services.dart';

enum SpeechPlaybackState { playing, completed, stopped, error }

class SpeechPlaybackEvent {
  const SpeechPlaybackEvent(
    this.state, {
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.message,
  });

  final SpeechPlaybackState state;
  final Duration position;
  final Duration duration;
  final String? message;
}

abstract class SpeechAudioPlayer {
  Stream<SpeechPlaybackEvent> get events;
  Future<void> play(Uint8List bytes);
  Future<void> stop();
  Future<void> dispose();
}

abstract interface class ProgressiveSpeechPlayer {
  Future<void> playUrl(Uri uri);
}

class SpeechPlaybackException implements Exception {
  const SpeechPlaybackException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Android MP3 playback. Recording's PCM output channel is deliberately separate.
/// The caller must keep BackgroundSession(mediaPlayback: true) active while
/// requesting or playing speech, including when the screen is locked.
class NativeSpeechAudioPlayer
    implements SpeechAudioPlayer, ProgressiveSpeechPlayer {
  NativeSpeechAudioPlayer({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('aihaptics/speech') {
    _channel.setMethodCallHandler(_onMethod);
  }

  static int _nextId = 0;
  static const maxAudioBytes = 20 * 1024 * 1024;
  final MethodChannel _channel;
  final _events = StreamController<SpeechPlaybackEvent>.broadcast();
  int? _activeId;
  NetworkTrace? _preparationTrace;
  int _operation = 0;
  bool _disposed = false;

  @override
  Stream<SpeechPlaybackEvent> get events => _events.stream;

  Future<void> _onMethod(MethodCall call) async {
    if (_disposed || call.arguments is! Map) return;
    if (call.method == 'diagnostic') {
      final info = call.arguments as Map;
      if (info['id'] != _activeId) return;
      final stage = const {
        'preparing': '原生播放器开始准备',
        'prepared': '原生播放器准备完成',
      }[info['stage']];
      if (stage != null) _preparationTrace?.mark(stage);
      return;
    }
    if (call.method != 'event') return;
    final data = call.arguments as Map;
    if (_activeId == null || data['id'] != _activeId) return;
    final state = switch (data['state']) {
      'playing' => SpeechPlaybackState.playing,
      'completed' => SpeechPlaybackState.completed,
      'stopped' => SpeechPlaybackState.stopped,
      'error' => SpeechPlaybackState.error,
      _ => null,
    };
    if (state == null) return;
    if (state != SpeechPlaybackState.playing) _activeId = null;
    _events.add(
      SpeechPlaybackEvent(
        state,
        position: _duration(data['positionMs']),
        duration: _duration(data['durationMs']),
        message: state == SpeechPlaybackState.error
            ? _errorMessage(data['code'])
            : null,
      ),
    );
  }

  static Duration _duration(Object? value) =>
      Duration(milliseconds: value is int ? value.clamp(0, 7200000) : 0);

  static String _errorMessage(Object? code) => switch (code) {
    'audio_focus_denied' => '其他应用正在使用音频，请稍后点击重试朗读。',
    'invalid_audio' => '语音文件无法播放，请重新生成语音。',
    'prepare_timeout' => '准备播放超时，请稍后点击重试朗读。',
    _ => '无法播放语音，请检查媒体音量或耳机后重试。',
  };

  @override
  Future<void> play(Uint8List bytes) async {
    if (_disposed) throw StateError('speech_player_disposed');
    if (bytes.isEmpty || bytes.length > maxAudioBytes) {
      throw const SpeechPlaybackException('语音文件为空或过大，请重新生成语音。');
    }
    await _start('play', {'bytes': bytes});
  }

  @override
  Future<void> playUrl(Uri uri) async {
    if (_disposed) throw StateError('speech_player_disposed');
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.port <= 0 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(r'^/speech/[a-f0-9]{64}\.mp3$').hasMatch(uri.path)) {
      throw const SpeechPlaybackException('本地音频地址无效。');
    }
    await _start('playUrl', {'url': uri.toString()});
  }

  Future<void> _start(String method, Map<String, Object> arguments) async {
    final id = ++_nextId;
    final operation = ++_operation;
    _activeId = id;
    _preparationTrace = NetworkTrace('播放准备');
    try {
      await _channel.invokeMethod<void>(method, {'id': id, ...arguments});
    } catch (error) {
      if (_disposed || operation != _operation) return;
      final message = error is MissingPluginException
          ? '此设备尚未加载语音播放组件，请安装新版手机应用。'
          : _errorMessage(error is PlatformException ? error.code : null);
      if (_activeId == id) {
        _activeId = null;
        _events.add(
          SpeechPlaybackEvent(SpeechPlaybackState.error, message: message),
        );
      }
      throw SpeechPlaybackException(message);
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    final wasActive = _activeId != null;
    final operation = ++_operation;
    _activeId = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // A stop before the Android player exists still invalidates callbacks.
    } finally {
      if (wasActive && !_disposed && operation == _operation) {
        _events.add(const SpeechPlaybackEvent(SpeechPlaybackState.stopped));
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _operation++;
    _activeId = null;
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Native activity/service destruction also releases the player.
    }
    await _events.close();
  }
}
