import 'package:flutter/material.dart';

import 'warm_theme.dart';

/// One controller per cold launch; lifecycle resume does not restart it.
class WarmSplash extends StatefulWidget {
  const WarmSplash({super.key, required this.child});
  final Widget child;
  @override
  State<WarmSplash> createState() => _WarmSplashState();
}

class _WarmSplashState extends State<WarmSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) setState(() {});
        })
        ..forward();
  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (animation.isCompleted) return widget.child;
    return Scaffold(
      backgroundColor: warmPaper,
      body: Center(
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final value = MediaQuery.disableAnimationsOf(context)
                ? 1.0
                : animation.value;
            final scale = Curves.easeOutCubic.transform(
              (value / .65).clamp(0.0, 1.0),
            );
            return Column(
              key: const Key('warm_splash'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.scale(
                  scale: .12 + .88 * scale,
                  child: const RoseAvatar(size: 100),
                ),
                const SizedBox(height: 30),
                Opacity(
                  opacity: ((value - .3) / .4).clamp(0.0, 1.0),
                  child: const Column(
                    children: [
                      Text(
                        'AI Haptics',
                        style: TextStyle(
                          color: warmInk,
                          fontSize: 27,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                        ),
                      ),
                      SizedBox(height: 10),
                      Text(
                        '让每一次互动，都有回应',
                        style: TextStyle(color: warmMuted, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
