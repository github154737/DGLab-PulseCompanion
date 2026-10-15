import 'dart:async';

import 'package:flutter/material.dart';

import 'venice_wave_session.dart';
import 'warm_theme.dart';

/// Only the active playback surface animates. Library previews use WarmWavePlot.
class WarmPlayback extends StatefulWidget {
  const WarmPlayback({super.key, required this.session, this.height = 64});
  final VeniceWaveSession session;
  final double height;
  @override
  State<WarmPlayback> createState() => _WarmPlaybackState();
}

class _WarmPlaybackState extends State<WarmPlayback> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    schedule();
  }

  @override
  void didUpdateWidget(WarmPlayback old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(changed);
      widget.session.addListener(changed);
    }
    schedule();
  }

  void changed() {
    if (mounted) {
      schedule();
      setState(() {});
    }
  }

  void schedule() {
    timer?.cancel();
    timer = null;
    if (widget.session.active && TickerMode.valuesOf(context).enabled) {
      timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted) return;
        if (!widget.session.active) schedule();
        setState(() {});
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.session.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final elapsed = s.started == null
        ? 0
        : s.now().difference(s.started!).inMilliseconds;
    // Native frames are sent every 100 ms. Imported shape timing is NOT yet
    // protocol-verified; its four-second cycle is explicitly a visual preview.
    final duration = s.wave.deviceReady
        ? s.wave.nativeFrames!.length * 100
        : 4000;
    final phase = s.active ? (elapsed % duration) / duration : 0.0;
    return Semantics(
      label: s.active ? '正在播放波形' : '静态波形预览',
      child: RepaintBoundary(
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: s.active
              ? CustomPaint(
                  key: const Key('active_wave_plot'),
                  painter: PlaybackPainter(
                    s.wave.levels,
                    phase,
                    s.wave.deviceReady,
                  ),
                )
              : WarmWavePlot(s.wave.levels, height: widget.height),
        ),
      ),
    );
  }
}

class PlaybackPainter extends CustomPainter {
  PlaybackPainter(this.levels, this.phase, this.stepped);
  final List<double> levels;
  final double phase;
  final bool stepped;
  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final grid = Paint()
      ..color = warmLine
      ..strokeWidth = .5;
    for (double x = 0; x < size.width; x += 20) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    final path = Path();
    for (int i = 0; i <= 200; i++) {
      final position = ((i / 200 + phase - .68) % 1) * levels.length;
      final index = position.floor() % levels.length;
      final next = (index + 1) % levels.length;
      final value = stepped
          ? levels[index]
          : levels[index] +
                (levels[next] - levels[index]) * (position - position.floor());
      final x = i / 200 * size.width,
          y = size.height - 4 - value.clamp(0.0, 1.0) * (size.height - 8);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = warmRose.withValues(alpha: .12));
    canvas.drawPath(
      path,
      Paint()
        ..color = warmRose
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    canvas.drawLine(
      Offset(size.width * .68, 0),
      Offset(size.width * .68, size.height),
      Paint()
        ..color = warmRose.withValues(alpha: .55)
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      Offset(size.width * .68, 4),
      3,
      Paint()..color = warmRose,
    );
  }

  @override
  bool shouldRepaint(PlaybackPainter old) =>
      phase != old.phase || levels != old.levels || stepped != old.stepped;
}
