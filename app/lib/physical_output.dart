import 'dart:async';

import 'package:flutter/foundation.dart';

import 'device_gateway.dart';
import 'coyote_ble.dart';
import 'network_diagnostics.dart';

/// Streams short, replacing tasks. No positive task survives a stop generation.
/// RPC completion confirms APP task processing, not electrode output measurement.
class PhysicalOutput extends ChangeNotifier {
  final _trace = NetworkTrace('实物输出');
  DglabV4Gateway? gateway;
  RemoteDevice? device;
  CoyoteBle? ble;
  VoidCallback? _bleListener;
  bool _bleFeeding = false;
  StreamSubscription<void>? _subscription;
  bool armed = false, stopping = false, unknown = false, _dead = false;
  int _generation = 0;
  final caps = [20, 20];
  String status = '实物输出未绑定 / No physical output bound';
  DateTime? _last;
  Future<void>? _stopFuture;
  VoidCallback? onFault;
  bool get canArm =>
      !armed &&
      !stopping &&
      !unknown &&
      (ble != null
          ? ble!.ready
          : gateway != null &&
                !gateway!.isClosed &&
                gateway!.deviceMap[device?.id]?.connectedCoyote == true);
  void changed() {
    if (!_dead) notifyListeners();
  }

  Future<void> bind(DglabV4Gateway next, RemoteDevice target) async {
    final reset = stop();
    final stamp = _generation;
    await reset;
    if (_dead || stamp != _generation) throw StateError('设备选择已取消');
    if (unknown) throw StateError('上次停止未确认，不能切换设备');
    if (target.kind != 'COYOTE_030') throw StateError('当前只支持郊狼 3.0 实物输出');
    if (next.isClosed || next.deviceMap[target.id]?.connectedCoyote != true) {
      throw StateError('请先在 DG-LAB 中连接郊狼 3.0 蓝牙设备');
    }
    _detachBle();
    await _subscription?.cancel();
    if (_dead ||
        stamp != _generation ||
        next.isClosed ||
        next.deviceMap[target.id]?.connectedCoyote != true) {
      throw StateError('设备选择已取消或连接已失效');
    }
    gateway = next;
    device = target;
    _subscription = next.changes.listen(
      (_) {
        if (next.deviceMap[target.id]?.connectedCoyote != true) {
          fail('设备已断开 / Device disconnected');
        }
        changed();
      },
      onDone: () {
        fail('连接已断开 / Connection closed');
        changed();
      },
    );
    status = '已选择设备，尚未启用输出 / Selected; output disabled';
    _trace.mark('设备绑定完成 · canArm=$canArm · 输出未启用');
    changed();
  }

  void _detachBle() {
    if (_bleListener != null) ble?.removeListener(_bleListener!);
    _bleListener = null;
    ble = null;
  }

  Future<void> release() async {
    await stop();
    if (unknown) return;
    await _subscription?.cancel();
    _subscription = null;
    _detachBle();
    gateway = null;
    device = null;
    changed();
  }

  Future<void> bindBle(CoyoteBle next) async {
    if (!next.ready) throw StateError('请等待蓝牙设备确认归零');
    // Same device's fresh initialization provides a new confirmed zero baseline.
    if (!(identical(ble, next) && next.ready && !armed)) await stop();
    if (unknown && !identical(ble, next)) throw StateError('原设备停止未确认，不能切换');
    await _subscription?.cancel();
    _subscription = null;
    _detachBle();
    gateway = null;
    device = RemoteDevice(
      id: next.id,
      name: next.name,
      kind: 'COYOTE_030',
      channels: 2,
    );
    ble = next;
    unknown = false;
    _bleListener = () {
      status = next.status;
      if (armed && !next.armed) {
        armed = false;
        _generation++;
        unknown = !next.ready;
        onFault?.call();
      }
      if (next.disconnected) {
        unknown = true;
      } else if (next.ready && !stopping) {
        unknown = false;
      }
      changed();
    };
    next.addListener(_bleListener!);
    status = next.status;
    changed();
  }

  Future<void> arm() async {
    _trace.mark(
      '启用请求 · canArm=$canArm armed=$armed stopping=$stopping unknown=$unknown',
    );
    if (!canArm) {
      throw StateError('请先连接设备');
    }
    if (ble case final link?) {
      final stamp = ++_generation;
      await link.arm(List<int>.of(caps));
      if (_dead || stamp != _generation || !link.armed) {
        await link.stop();
        throw StateError('启用已取消');
      }
      armed = true;
      unknown = false;
      _last = null;
      changed();
      return;
    }
    final reset =
        stop(); // Clear/reset both channels before any local output is allowed.
    final stamp = _generation;
    await reset;
    if (stamp != _generation || _dead) throw StateError('启用已取消');
    if (unknown ||
        gateway!.isClosed ||
        gateway!.deviceMap[device!.id]?.connectedCoyote != true) {
      throw StateError('无法确认设备就绪');
    }
    _generation++;
    armed = true;
    _last = null;
    _trace.mark('DG-LAB 归零回执已确认 · 输出已启用 · 上限 A=${caps[0]} B=${caps[1]}');
    status =
        '实物输出已启用，等待本地授权 / Physical output armed; awaiting local authorization';
    changed();
  }

  void consume(Map<String, dynamic> state) {
    if (!armed || stopping || device == null) return;
    if (!['authorized', 'playing'].contains(state['phase']) ||
        state['device']?['id'] != 'sim_dglab') {
      unawaited(stop());
      return;
    }
    if (ble case final link?) {
      if (_bleFeeding) {
        return; // Never build a backlog across the platform channel.
      }
      final stamp = _generation;
      _bleFeeding = true;
      unawaited(
        link
            .feed(state, List<int>.of(caps))
            .catchError((Object _) {
              if (armed && stamp == _generation) fail('蓝牙目标提交失败，已请求停止');
            })
            .whenComplete(() => _bleFeeding = false),
      );
      return;
    }
    if (gateway == null) return;
    if (_last != null &&
        DateTime.now().difference(_last!) < const Duration(milliseconds: 95)) {
      return;
    }
    _last = DateTime.now();
    final stamp = _generation, g = gateway!, d = device!;
    final live = g.deviceMap[d.id];
    if (live == null || !live.connectedCoyote) {
      fail('设备已断开 / Device disconnected');
      return;
    }
    final output = state['dglab_output'];
    if (output is! List || output.length != 2) {
      fail('核心输出格式无效 / Invalid core output');
      return;
    }
    for (var channel = 0; channel < 2; channel++) {
      final frame = output[channel]['frame'],
          scale = output[channel]['strength_scale'];
      if (frame is! String ||
          !RegExp(r'^[0-9A-Fa-f]{16}$').hasMatch(frame) ||
          scale is! num ||
          !scale.isFinite ||
          scale < 0 ||
          scale > 1 ||
          caps[channel] < 0 ||
          caps[channel] > 200) {
        fail('输出校验失败 / Output rejected');
        return;
      }
    }
    for (var channel = 0; channel < 2; channel++) {
      final remaining = (state['remaining_ms'] as num).toInt();
      if (remaining < 100) {
        unawaited(stop());
        return;
      }
      final strength =
          ((output[channel]['strength_scale'] as num) *
                  effectiveCap(live, channel))
              .floor();
      void send(Map<String, dynamic> op) {
        if (!armed || stamp != _generation) return;
        unawaited(
          g.operate(d, op).then((_) {}).catchError((Object _) {
            if (armed && stamp == _generation) {
              fail('设备任务未完成，已请求停止 / Device task failed; stop requested');
            }
          }),
        );
      }

      send({
        't': 0,
        'c': channel,
        'p': 1,
        'd': 100,
        'im': true,
        'ver': 3,
        'v': [output[channel]['frame']],
      });
      send({
        't': 4,
        'c': channel,
        'p': 1,
        'd': remaining.clamp(100, 200),
        'im': true,
        'v': strength,
      });
    }
    if (!armed) return;
    status = '已发送短时任务；实物状态以 APP 为准 / Short tasks sent; check APP for actual device state';
    changed();
  }

  void fail(String message) {
    if (!armed && !stopping) return;
    unknown = true;
    status = message;
    unawaited(stop());
    onFault?.call();
    changed();
  }

  int effectiveCap(RemoteDevice live, int channel) {
    final name = channel == 0 ? 'channelA' : 'channelB';
    final telemetry = live.details['slotState']?[name];
    final fault = live.details['props']?['${name}Status'];
    if (fault == 3) {
      fail('设备通道报告损坏 / Device reports channel fault');
      return 0;
    }
    var cap = caps[channel];
    if (telemetry is Map) {
      if (telemetry['comfortLimit'] is Map &&
          telemetry['comfortLimit']['overheat'] == true) {
        cap = cap.clamp(0, 20);
      }
      if (telemetry['intensityMax'] is num) {
        cap = cap.clamp(
          0,
          (telemetry['intensityMax'] as num).clamp(0, 200).floor(),
        );
      }
      if (telemetry['isMuted'] == true) cap = 0;
    }
    return fault == 4 ? 0 : cap;
  }

  Future<void> stop() {
    armed = false;
    _generation++;
    _last = null;
    if (_stopFuture != null) return _stopFuture!;
    if (ble case final link?) {
      stopping = true;
      changed();
      final future = () async {
        try {
          await link.stop();
          unknown = false;
          status = link.status;
        } catch (_) {
          unknown = true;
          status = '蓝牙停止未确认，请在设备上停止；重新连接需再次授权';
        } finally {
          stopping = false;
          _stopFuture = null;
          changed();
        }
      }();
      _stopFuture = future;
      return future;
    }
    final g = gateway, d = device;
    if (g == null || d == null) return Future.value();
    stopping = true;
    status = '正在请求实物停止 / Requesting physical stop';
    changed();
    final future = () async {
      try {
        // Synchronous send ordering is clear -> reset A/B. Late completions cannot enqueue output.
        final clear = g.operate(d, {}, clear: true);
        final a = g.operate(d, {'t': 7, 'c': 0, 'p': 2, 'v': 0});
        final b = g.operate(d, {'t': 7, 'c': 1, 'p': 2, 'v': 0});
        final replies = await Future.wait([clear, a, b]);
        if (replies[1]['reason'] != 'completed' ||
            replies[2]['reason'] != 'completed') {
          throw StateError('归零未完成');
        }
        unknown = false;
        status = 'APP 已确认清理并归零；未测量实物输出 / APP acknowledged clear/reset; physical output not measured';
      } catch (_) {
        unknown = true;
        status =
            '实物停止未确认，请在设备 / APP 停止 / Stop unconfirmed; stop on device or APP';
      } finally {
        stopping = false;
        _stopFuture = null;
        _trace.mark('停止回执 · 已确认=${!unknown} · 输出已撤销');
        changed();
      }
    }();
    _stopFuture = future;
    return future;
  }

  @override
  void dispose() {
    _dead = true;
    unawaited(stop());
    _detachBle();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
