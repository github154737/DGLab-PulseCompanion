import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/app_distribution.dart';
import 'package:haptics_lab/warm_theme.dart';
import 'package:haptics_lab/warm_splash.dart';
import 'package:haptics_lab/venice_route.dart';

void main() {
  test('private route cannot be changed through public setup', () {
    if (AppDistribution.compiled.edition == 'pilot') {
      expect(
        () => VeniceRoute.configurePublic(
          url: 'https://example.com/api/v1',
          token: 'fixture',
        ),
        throwsStateError,
      );
    } else {
      expect(AppDistribution.compiled.loginEnabled, isFalse);
    }
  });
  testWidgets('compiled distribution follows splash and selects its own gate', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: warmTheme(),
        home: const WarmSplash(child: DistributionGate()),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    if (AppDistribution.compiled.edition == 'pilot') {
      expect(find.byKey(const Key('pilot_login')), findsOneWidget);
      expect(find.text('配置你的服务'), findsNothing);
    } else {
      expect(find.text('配置你的服务'), findsOneWidget);
      expect(find.byKey(const Key('pilot_login')), findsNothing);
    }
  });
}
