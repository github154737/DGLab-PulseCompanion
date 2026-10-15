import 'dart:io';

import 'package:flutter/services.dart';

import 'network_diagnostics.dart';
import 'venice_route.dart';

/// Receives only a change signal, never SSIDs, IPs or network identifiers.
class NetworkLifecycle {
  static const _channel = MethodChannel('aihaptics/network');
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') {
        VeniceRoute.connections.invalidate();
        NetworkTrace('网络').mark('网络路径变化，后续请求重新建连');
      }
    });
    try {
      await _channel.invokeMethod<void>('watch');
    } on PlatformException {
      // Transport errors also invalidate the pool if callbacks are unavailable.
    } on MissingPluginException {
      // Older native hosts remain usable.
    }
  }
}
