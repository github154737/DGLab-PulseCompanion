import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'speech_output.dart';
import 'warm_theme.dart';

const speechVoiceLabels = {
  'eve': 'Eve · 明快女声',
  'ara': 'Ara · 温暖女声',
  'rex': 'Rex · 清晰男声',
  'sal': 'Sal · 平稳音色',
};

class SpeechMessageControl extends StatelessWidget {
  const SpeechMessageControl({
    super.key,
    required this.output,
    required this.message,
    required this.onPlay,
    this.compact = false,
  });
  final SpeechOutput output;
  final Object message;
  final VoidCallback? onPlay;
  final bool compact;
  String time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: output,
    builder: (context, _) {
      final selected = identical(message, output.message);
      final active = selected && output.active;
      final playing = active && output.phase == SpeechOutputPhase.playing;
      final failed = selected && output.phase == SpeechOutputPhase.failed;
      final label = active
          ? playing
                ? '正在朗读'
                : '正在生成语音'
          : failed
          ? '重试朗读'
          : '朗读';
      if (compact) {
        return IconButton(
          key: ValueKey('speech_button_${identityHashCode(message)}'),
          tooltip: failed ? '$label：${output.error}' : label,
          onPressed: active ? output.stop : onPlay,
          icon: Icon(
            active
                ? Icons.stop_circle_outlined
                : failed
                ? Icons.refresh
                : Icons.volume_up_outlined,
            size: 20,
            color: warmRose,
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                key: ValueKey('speech_button_${identityHashCode(message)}'),
                onPressed: active ? output.stop : onPlay,
                icon: Icon(
                  active
                      ? Icons.stop_rounded
                      : failed
                      ? Icons.refresh_rounded
                      : Icons.volume_up_rounded,
                  size: 19,
                ),
                label: Text(label, style: const TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(48, 44),
                ),
              ),
              if (active) VoiceBars(playing: playing),
              if (playing && output.duration > Duration.zero)
                Text(
                  '${time(output.position)} / ${time(output.duration)}',
                  style: const TextStyle(fontSize: 11, color: warmMuted),
                ),
              if (active && output.segments > 1)
                Text(
                  '${output.segment}/${output.segments} 段',
                  style: const TextStyle(fontSize: 11, color: warmMuted),
                ),
            ],
          ),
          if (playing && output.duration > Duration.zero)
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value:
                    (output.position.inMilliseconds /
                            output.duration.inMilliseconds)
                        .clamp(0, 1),
                minHeight: 2,
                backgroundColor: warmLine,
                color: warmRose,
                semanticsLabel: '朗读进度',
              ),
            ),
          if (failed)
            Text(
              output.error,
              key: const Key('speech_error'),
              style: const TextStyle(fontSize: 11, color: warmRose),
            ),
        ],
      );
    },
  );
}

/// A playback-state animation, not microphone levels or electrical waveform data.
class VoiceBars extends StatefulWidget {
  const VoiceBars({super.key, required this.playing});
  final bool playing;
  @override
  State<VoiceBars> createState() => _VoiceBarsState();
}

class _VoiceBarsState extends State<VoiceBars>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  void sync() {
    if (widget.playing &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled) {
      if (!animation.isAnimating) animation.repeat();
    } else {
      animation.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(covariant VoiceBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync();
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.playing ? '语音播放中' : '等待语音',
    child: RepaintBoundary(
      child: CustomPaint(
        key: const Key('speech_voice_bars'),
        size: const Size(35, 22),
        painter: _VoiceBarsPainter(animation, widget.playing),
      ),
    ),
  );
}

class _VoiceBarsPainter extends CustomPainter {
  _VoiceBarsPainter(this.animation, this.playing) : super(repaint: animation);
  final Animation<double> animation;
  final bool playing;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = warmRose.withValues(alpha: playing ? .9 : .4);
    for (var i = 0; i < 5; i++) {
      final h = playing
          ? 5 +
                15 *
                    (.5 +
                        .5 * math.sin(animation.value * math.pi * 2 + i * 1.3))
          : 4.0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * 7, (size.height - h) / 2, 3.5, h),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceBarsPainter oldDelegate) =>
      oldDelegate.playing != playing || oldDelegate.animation != animation;
}
