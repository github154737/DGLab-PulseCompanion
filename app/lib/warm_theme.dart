import 'package:flutter/material.dart';

const warmPaper = Color(0xFFF8F4F0);
const warmRose = Color(0xFFA9586D);
const warmInk = Color(0xFF463541);
const warmMuted = Color(0xFF80747B);
const warmLine = Color(0xFFE9DFDF);

ThemeData warmTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: warmRose,
        brightness: Brightness.light,
      ).copyWith(
        primary: warmRose,
        surface: warmPaper,
        onSurface: warmInk,
        outlineVariant: warmLine,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: warmPaper,
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        fontSize: 27,
        fontWeight: FontWeight.w600,
        color: warmInk,
      ),
      titleLarge: TextStyle(
        fontSize: 21,
        fontWeight: FontWeight.w600,
        color: warmInk,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: warmInk,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.55, color: warmInk),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: warmInk),
      bodySmall: TextStyle(fontSize: 12, height: 1.45, color: warmMuted),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: warmPaper,
      foregroundColor: warmInk,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF0E9E7),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: BorderSide.none,
      ),
      hintStyle: const TextStyle(color: warmMuted, fontSize: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        side: const BorderSide(color: warmRose),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    dividerTheme: const DividerThemeData(color: warmLine),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: const Color(0xFFF1E7E6),
      selectedColor: const Color(0xFFE9CDD4),
      labelStyle: const TextStyle(fontFamily: 'Roboto', fontSize: 12, color: warmInk),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: warmPaper,
      indicatorColor: const Color(0xFFF0DCE0),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 12,
          color: s.contains(WidgetState.selected) ? warmRose : warmMuted,
        ),
      ),
    ),
  );
}

class WarmCard extends StatelessWidget {
  const WarmCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.tint,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? tint;
  @override
  Widget build(BuildContext context) => Material(
    color: tint ?? const Color(0xFFFFFCFA),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: const BorderSide(color: warmLine),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class RoseAvatar extends StatelessWidget {
  const RoseAvatar({super.key, this.size = 44});
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-.5, -.6),
              colors: [Color(0xFFF9E2DC), Color(0xFFE3B9B8), Color(0xFFC38698)],
              radius: 1.2,
            ),
          ),
          child: Align(
            alignment: const Alignment(.5, 1.1),
            child: Container(
              width: size * .65,
              height: size * .40,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFFBD7A8D), Color(0xFFF0D8D2)],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class WarmBadge extends StatelessWidget {
  const WarmBadge(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xFFF1E2E3),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Text(label, style: const TextStyle(fontSize: 12, color: warmRose)),
  );
}

class WarmWavePlot extends StatelessWidget {
  const WarmWavePlot(
    this.levels, {
    super.key,
    this.height = 60,
    this.color = warmRose,
  });
  final List<double> levels;
  final double height;
  final Color color;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _WavePainter(levels, color)),
    ),
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.levels, this.color);
  final List<double> levels;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (levels.length < 2) return;
    final grid = Paint()
      ..color = warmLine.withValues(alpha: .45)
      ..strokeWidth = .6;
    for (var x = 0.0; x < size.width; x += 18) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    final path = Path();
    final count = levels.length.clamp(2, 400);
    for (var i = 0; i < count; i++) {
      final value = levels[(i * (levels.length - 1) / (count - 1)).round()]
          .clamp(0.0, 1.0);
      final x = i * size.width / (count - 1),
          y = size.height - 5 - value * (size.height - 10);
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
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .15), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.7
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.levels != levels || old.color != color;
}
