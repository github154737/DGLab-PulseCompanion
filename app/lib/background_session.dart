import 'dart:io';

import 'package:flutter/services.dart';

/// A foreground-started Android service keeps only user-started work alive.
/// It never restarts a recording or grants waveform authority.
class BackgroundSession {
  static const channel = MethodChannel('aihaptics/background');
  void Function()? onStop;
  void Function()? onPauseVoice;
  void Function()? onEndVoice;
  bool _dead = false;
  String _state = '';
  Future<bool> _pending = Future.value(true);

  BackgroundSession() {
    if (Platform.isAndroid) {
      channel.setMethodCallHandler((call) async {
        if (_dead) return;
        if (call.method == 'stop') onStop?.call();
        if (call.method == 'pauseVoice') onPauseVoice?.call();
        if (call.method == 'endVoice') onEndVoice?.call();
      });
    }
  }

  Future<bool> update({
    required bool active,
    bool microphone = false,
    bool device = false,
    bool simulation = false,
    bool mediaPlayback = false,
    bool continuous = false,
  }) {
    if (!Platform.isAndroid || _dead) return Future.value(true);
    final signature =
        '$active/$microphone/$device/$simulation/$mediaPlayback/$continuous';
    _pending = _pending.then((_) async {
      if (_dead || signature == _state) return true;
      try {
        final ok = await channel
            .invokeMethod<bool>('update', {
              'active': active,
              'microphone': microphone,
              'device': device,
              'simulation': simulation,
              'mediaPlayback': mediaPlayback,
              'continuous': continuous,
            })
            .timeout(const Duration(seconds: 8));
        if (ok == true) _state = signature;
        return ok == true;
      } catch (_) {
        return false;
      }
    });
    return _pending;
  }

  void dispose() {
    _dead = true;
    if (Platform.isAndroid) {
      channel.setMethodCallHandler(null);
      channel.invokeMethod<void>('stop').catchError((_) {});
    }
  }
}
