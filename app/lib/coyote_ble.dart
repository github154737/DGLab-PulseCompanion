import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native service owns BLE timing, acknowledgements and authorization deadline.
/// This client only supplies validated targets and presents reported device state.
class CoyoteBle extends ChangeNotifier {
  CoyoteBle({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('aihaptics/coyote_ble') {
    this.channel.setMethodCallHandler((call) async {
      if (call.method == 'event' && call.arguments is Map) {
        accept(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
  }
  final MethodChannel channel;
  Map<String, dynamic> state = const {};
  bool _dead = false;
  int? _grant;
  bool get ready => state['state'] == 'ready';
  bool get armed => state['state'] == 'armed';
  bool get disconnected =>
      ['disconnected', 'fault', null].contains(state['state']);
  bool get scanning => state['scanning'] == true;
  String get status => state['status'] as String? ?? '尚未扫描设备';
  String get name => state['name'] as String? ?? '郊狼 3.0';
  String get id => state['id'] as String? ?? '';
  int? get actualA => state['a'] as int?;
  int? get actualB => state['b'] as int?;
  List<Map<String, dynamic>> get devices => (state['devices'] as List? ?? [])
      .map((v) => Map<String, dynamic>.from(v as Map))
      .toList();
  @visibleForTesting
  void accept(Map<String, dynamic> value) {
    if (_dead) return;
    state = value;
    if (!armed) _grant = null;
    notifyListeners();
  }

  Future<bool> permissions() async =>
      await channel.invokeMethod<bool>('permissions') == true;
  Future<void> scan() => channel.invokeMethod<void>('scan');
  Future<void> stopScan() => channel.invokeMethod<void>('stopScan');
  Future<void> connect(String id) async {
    final value = await channel.invokeMapMethod<String, dynamic>('connect', {
      'id': id,
    });
    if (value != null) accept(value);
  }

  Future<void> arm(List<int> caps) async {
    final result = await channel
        .invokeMapMethod<String, dynamic>('arm', {'a': caps[0], 'b': caps[1]})
        .timeout(const Duration(seconds: 5));
    if (_dead || result == null || result['state'] != 'armed') {
      throw StateError('蓝牙启用未确认');
    }
    accept(result);
    _grant = result['generation'] as int;
  }

  Future<void> feed(Map<String, dynamic> value, List<int> caps) async {
    if (_grant == null || !armed) throw StateError('蓝牙授权已失效');
    final frames = value['dglab_output'];
    if (frames is! List ||
        frames.length != 2 ||
        value['remaining_ms'] is! int) {
      throw const FormatException('输出结构无效');
    }
    final levels = <int>[];
    for (var i = 0; i < 2; i++) {
      final row = frames[i];
      if (row is! Map ||
          row['frame'] is! String ||
          !RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(row['frame'] as String)) {
        throw const FormatException('波形无效');
      }
      final scale = row['strength_scale'];
      if (scale is! num ||
          !scale.isFinite ||
          scale < 0 ||
          scale > 1 ||
          caps[i] < 0 ||
          caps[i] > 50) {
        throw const FormatException('强度超出范围');
      }
      levels.add((scale * caps[i]).floor());
    }
    await channel
        .invokeMethod<void>('feed', {
          'a': levels[0],
          'b': levels[1],
          'fa': frames[0]['frame'],
          'fb': frames[1]['frame'],
          'remaining': value['remaining_ms'],
          'generation': _grant,
        })
        .timeout(const Duration(seconds: 2));
  }

  Future<void> stop() async {
    _grant = null;
    final result = await channel
        .invokeMapMethod<String, dynamic>('stop')
        .timeout(const Duration(seconds: 4));
    if (result == null || result['state'] != 'ready') {
      throw StateError('设备停止未确认');
    }
    accept(result);
  }

  Future<void> disconnect() async {
    _grant = null;
    await channel.invokeMethod<void>('disconnect');
  }

  @override
  void dispose() {
    _dead = true;
    channel.setMethodCallHandler(null);
    unawaited(disconnect().catchError((Object _) {}));
    super.dispose();
  }
}
