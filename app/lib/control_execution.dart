import 'dart:convert';

/// Immutable local evidence. A target update is never a hardware acknowledgement.
class ControlExecution {
  ControlExecution({
    required this.status,
    required this.reason,
    required this.action,
    required Map<String, dynamic> before,
    required Map<String, dynamic> after,
    required this.text,
  }) : before = Map.unmodifiable(_state(before)),
       after = Map.unmodifiable(_state(after));

  final String status, reason, action, text;
  final Map<String, dynamic> before, after;
  static Map<String, dynamic> _state(Map<String, dynamic> value) => {
    for (final key in [
      'epoch',
      'authorized',
      'mode',
      'a',
      'b',
      'cap',
      'max_increase_per_turn',
      'selected',
    ])
      key: value[key],
  };
  bool get applied =>
      status == 'simulation_applied' || status == 'target_updated';
  bool get changed =>
      before['a'] != after['a'] ||
      before['b'] != after['b'] ||
      before['selected'] != after['selected'];
  bool matches(Map<String, dynamic> state) =>
      jsonEncode(after) == jsonEncode(_state(state));
  Map<String, dynamic> toJson() => {
    'status': status,
    'reason': reason,
    'action': action,
    'before': before,
    'after': after,
    'waveform_changed': before['selected'] != after['selected'],
    'device_acknowledged': false,
    'physical_output_measured': false,
  };

  String summary(Map<String, dynamic> current, {bool retry = false}) {
    final values = 'A=${current['a']} / B=${current['b']}';
    if (retry || !matches(current)) {
      return '本轮没有再次调整；当前${current['mode'] == 'simulation' ? '模拟' : '本地目标'}为 $values，${current['authorized'] == true ? '会话运行中' : '会话已停止'}。';
    }
    if (applied && !changed) return '本轮保持当前波形和强度，$values。';
    final waveform = before['selected'] != after['selected']
        ? '，波形已切换'
        : '，波形未改变';
    return switch (status) {
      'simulation_applied' => '本轮模拟已执行：$values$waveform。',
      'target_updated' => '本轮本地目标已更新为 $values$waveform；尚无对应的设备执行确认。',
      'stopped' => '本轮已停止本地会话，强度归零。',
      'stop_requested' => '本轮已归零本地目标并请求停止；实物停止结果尚待确认。',
      'held' => '本轮保持当前波形和强度，$values。',
      'not_authorized' => '本轮没有调整；请先在互动页启用输出。',
      _ => '这轮没有完成调整；当前本地状态为 $values。',
    };
  }
}
