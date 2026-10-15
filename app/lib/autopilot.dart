import 'dart:async';

/// Serial, finite automatic conversation rounds. This never grants device control.
class Autopilot {
  Autopilot({
    required this.allowed,
    required this.runRound,
    required this.onChanged,
    this.canRun,
  });
  final bool Function() allowed;
  final Future<void> Function() runRound;
  final void Function() onChanged;
  final bool Function()? canRun;
  Timer? _timer;
  int _generation = 0;
  bool active = false, busy = false;
  int completed = 0, maxRounds = 12;
  Duration interval = const Duration(seconds: 15);
  String status = '未运行';
  void start({required Duration every, int rounds = 12}) {
    if (every < const Duration(seconds: 5) ||
        every > const Duration(seconds: 120) ||
        rounds < 1 ||
        rounds > 24) {
      throw ArgumentError('自动回合参数超出范围');
    }
    stop();
    interval = every;
    maxRounds = rounds;
    completed = 0;
    active = true;
    status = '等待下一个自动回合';
    onChanged();
    _schedule(_generation);
  }

  void _schedule(int stamp) {
    _timer = Timer(interval, () async {
      if (!active || stamp != _generation) return;
      if (!allowed()) {
        stop(reason: '自动回合已暂停');
        return;
      }
      if (busy || canRun?.call() == false) {
        _schedule(stamp);
        return;
      }
      busy = true;
      status = '正在生成自动回复';
      onChanged();
      try {
        await runRound();
      } catch (_) {
        if (stamp == _generation) stop(reason: '自动回合失败，已暂停');
      } finally {
        if (stamp == _generation) {
          busy = false;
          completed++;
          if (active && completed < maxRounds && allowed()) {
            status = '已完成 $completed / $maxRounds 回合';
            onChanged();
            _schedule(stamp);
          } else {
            stop(reason: '自动回合已结束');
          }
        }
      }
    });
  }

  void stop({String reason = '自动回合已停止'}) {
    _generation++;
    _timer?.cancel();
    _timer = null;
    active = false;
    busy = false;
    status = reason;
    onChanged();
  }

  void dispose() {
    _generation++;
    _timer?.cancel();
    active = false;
  }
}
