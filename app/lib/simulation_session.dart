import 'dart:convert';

import 'realtime_probe.dart';

/// All authority is local. Plans cannot extend authorization or the watchdog.
class SimulationSession {
  SimulationSession(this.core, this.receipt, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final ProbeCore core;
  final void Function(Map<String, dynamic>) receipt;
  final DateTime Function() now;
  DateTime? deadline;
  double gainCeiling = 0.7;
  int generation = 0;
  bool planningEnabled = false;
  final List<Map<String, dynamic>> _steps = [];
  String status = '尚未授权自主模拟';
  bool get active => deadline != null && now().isBefore(deadline!);
  int get queued => _steps.length;
  int get remaining => active ? deadline!.difference(now()).inSeconds : 0;
  Map<String, dynamic> grant({
    int seconds = 60,
    double limit = 0.3,
    double ceiling = 0.7,
  }) {
    if (seconds < 5 ||
        seconds > 180 ||
        !ceiling.isFinite ||
        ceiling < 0.5 ||
        ceiling > 1 ||
        !limit.isFinite ||
        limit < 0 ||
        limit > 0.5) {
      return {'ok': false, 'error': 'invalid_scope'};
    }
    stop();
    core({'op': 'connect', 'device_id': 'sim_single'});
    core({'op': 'set_ai_control', 'enabled': true});
    final result = core({
      'op': 'authorize_simulation_session',
      'limit': limit,
      'lease_ms': seconds * 1000,
    });
    if (result['ok'] == true) {
      deadline = now().add(Duration(seconds: seconds));
      planningEnabled = true;
      gainCeiling = ceiling;
      status = '自主模拟已授权，等待计划';
    }
    return result;
  }

  Map<String, dynamic> schedule(dynamic raw, int? ticket) {
    Map<String, dynamic> reject(String code) => {'ok': false, 'error': code};
    if (!active || ticket == null) return reject('not_authorized');
    if (raw is! List || raw.isEmpty || raw.length > 6) {
      return reject('invalid_plan');
    }
    final pending = <Map<String, dynamic>>[];
    var previous = -3000;
    for (final step in raw) {
      if (step is! Map ||
          step.length != 2 ||
          step['after_ms'] is! int ||
          ![
            'increase',
            'decrease',
            'gentle_wave',
            'soft_pulse',
            'stop',
            'hold',
          ].contains(step['action'])) {
        return reject('invalid_step');
      }
      final ms = step['after_ms'] as int;
      if (ms < 0 ||
          ms > 30000 ||
          ms - previous < 3000 ||
          !now().add(Duration(milliseconds: ms)).isBefore(deadline!)) {
        return reject('plan_outside_scope');
      }
      previous = ms;
      pending.add({
        'at': now().add(Duration(milliseconds: ms)),
        'action': step['action'],
      });
    }
    final validated = core({
      'op': 'complete_ai',
      'ticket': ticket,
      'response': jsonEncode({'action': 'noop'}),
    });
    if (validated['ok'] != true) return reject('stale_plan');
    _steps
      ..clear()
      ..addAll(pending);
    planningEnabled = true;
    generation++;
    status = '已安排 ${pending.length} 步，随时可接管';
    return {
      'ok': true,
      'scheduled': pending.length,
      'executed': false,
      'simulation_only': true,
      'generation': generation,
    };
  }

  void feedback() {
    planningEnabled = false;
    _steps.clear();
    generation++;
    status = active ? '用户反馈优先，旧计划已撤销' : status;
  }

  void stop() {
    planningEnabled = false;
    _steps.clear();
    deadline = null;
    generation++;
    core({'op': 'stop'});
    status = '已停止，需重新授权';
  }

  void tick() {
    if (deadline == null) return;
    if (!active) {
      stop();
      status = '自主时段已结束';
      return;
    }
    final beat = core({'op': 'simulation_heartbeat'});
    if (beat['ok'] != true) {
      stop();
      status = '控制权限已失效';
      return;
    }
    if (_steps.isEmpty || now().isBefore(_steps.first['at'] as DateTime)) {
      return;
    }
    final step = _steps.removeAt(0), action = step['action'] as String;
    if (action == 'stop') {
      stop();
      receipt({'ok': true, 'action': 'stop', 'executed': true});
      return;
    }
    final before = (core({'op': 'snapshot'})['state']['gain_target'] as num)
        .toDouble();
    final intent = action == 'hold'
        ? {'action': 'noop'}
        : ['increase', 'decrease'].contains(action)
        ? {
            'action': 'set_gain',
            'gain': (before + (action == 'increase' ? 0.1 : -0.1)).clamp(
              0.0,
              gainCeiling,
            ),
          }
        : {
            'action': 'play_preset',
            'device_alias': 'sim_single',
            'preset_id': action,
          };
    final ticket = core({'op': 'begin_ai'})['result']?['ticket'];
    final result = ticket == null
        ? {'ok': false, 'error': 'not_authorized'}
        : core({
            'op': 'complete_ai',
            'ticket': ticket,
            'response': jsonEncode(intent),
          });
    receipt({
      'ok': result['ok'],
      'action': action,
      'executed': result['ok'] == true,
      'generation': generation,
      'gain_target': core({'op': 'snapshot'})['state']['gain_target'],
      if (result['error'] != null) 'error': result['error'],
    });
    if (result['ok'] != true) {
      stop();
      status = '计划执行失败，已停止';
    } else if (_steps.isEmpty) {
      status = '本段计划完成';
    }
  }
}
