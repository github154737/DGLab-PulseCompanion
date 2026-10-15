import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/connection_panel.dart';
import 'package:haptics_lab/physical_output.dart';
import 'package:haptics_lab/venice_wave_session.dart';
import 'package:haptics_lab/warm_interaction.dart';
import 'package:haptics_lab/warm_library.dart';
import 'package:haptics_lab/warm_strength_limits.dart';
import 'package:haptics_lab/warm_theme.dart';

class ReadyPhysical extends PhysicalOutput {
  ReadyPhysical({this.ready = false});
  bool ready;
  int armCalls = 0;
  @override
  bool get canArm => ready && !armed && !unknown && !stopping;
  @override
  Future<void> arm() async {
    if (!canArm) throw StateError('not ready');
    armCalls++;
    armed = true;
    changed();
  }
}

void main() {
  test(
    'user session refuses simulation and retains device state after stop',
    () {
      final s = VeniceWaveSession(allowSimulation: false);
      expect(s.snapshot()['mode'], 'device');
      expect(s.active, false);
      expect(() => s.grant(), throwsStateError);
      expect(s.active, false);
      expect(s.strength, [0, 0]);
      s.grant(
        toDevice: true,
      ); // Local authority test only; no transport is bound.
      expect(s.active, true);
      expect(s.physical, true);
      final epoch = s.epoch;
      expect(() => s.grant(toDevice: false), throwsStateError);
      expect(s.active, true);
      expect(s.epoch, epoch);
      s.stop();
      expect(s.snapshot()['mode'], 'device');
      expect(s.active, false);
      s.dispose();
    },
  );

  test('administrator session can grant and stop simulation', () {
    final s = VeniceWaveSession(allowSimulation: true);
    s.grant();
    expect(s.active, true);
    expect(s.snapshot()['mode'], 'simulation');
    s.stop();
    expect(s.active, false);
    expect(s.strength, [0, 0]);
    s.dispose();
  });

  for (final admin in [false, true]) {
    testWidgets('interaction role admin=$admin exposes only allowed start', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(430, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final s = VeniceWaveSession(allowSimulation: admin);
      final library = WarmLibrary(s)..ready = true;
      final physical = ReadyPhysical();
      var beforeStarts = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: warmTheme(),
          home: Scaffold(
            body: WarmInteractionPage(
              developerAccess: admin,
              library: library,
              physical: physical,
              stop: s.stop,
              beforeStart: () async {
                beforeStarts++;
                return true;
              },
            ),
          ),
        ),
      );
      expect(find.text('开始模拟'), admin ? findsOneWidget : findsNothing);
      expect(find.text('模拟模式'), admin ? findsOneWidget : findsNothing);
      final start = find.byKey(const Key('venice_wave_grant'));
      await tester.tap(start);
      await tester.pump();
      if (admin) {
        expect(s.active, true);
        expect(s.physical, false);
        expect(beforeStarts, 1);
      } else {
        expect(s.active, false);
        expect(beforeStarts, 0);
        expect(find.byType(ConnectionPanel), findsOneWidget);
        expect(find.byKey(const Key('gateway_endpoint')), findsNothing);
        expect(find.byType(DropdownButtonFormField<String>), findsNothing);
        expect(find.textContaining('模拟'), findsNothing);
      }
      expect(physical.armCalls, 0);
      s.stop();
      await tester.pumpWidget(const SizedBox());
      physical.dispose();
      library.dispose();
      s.dispose();
    });
  }

  testWidgets(
    'user start explicitly arms a ready device, no simulation fallback',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final s = VeniceWaveSession(allowSimulation: false);
      final library = WarmLibrary(s)..ready = true;
      final physical = ReadyPhysical(ready: true);
      var beforeStarts = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: warmTheme(),
          home: Scaffold(
            body: WarmInteractionPage(
              library: library,
              physical: physical,
              stop: s.stop,
              beforeStart: () async {
                beforeStarts++;
                return true;
              },
            ),
          ),
        ),
      );
      expect(s.active, false);
      expect(physical.armCalls, 0);
      expect(find.text('启用实物输出'), findsOneWidget);
      await tester.tap(find.byKey(const Key('venice_wave_grant')));
      await tester.pump();
      expect(beforeStarts, 1);
      expect(physical.armCalls, 1);
      expect(s.active, true);
      expect(s.physical, true);
      expect(s.strength, [0, 0]);
      expect(find.textContaining('模拟'), findsNothing);
      s.stop();
      await tester.pumpWidget(const SizedBox());
      physical.dispose();
      library.dispose();
      s.dispose();
    },
  );

  testWidgets(
    'user strength controls remain available without developer text',
    (tester) async {
      final s = VeniceWaveSession(allowSimulation: false);
      final library = WarmLibrary(s)..ready = true;
      final physical = ReadyPhysical();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StrengthLimitsSheet(library: library, physical: physical),
          ),
        ),
      );
      expect(find.byKey(const Key('strength_cap')), findsOneWidget);
      expect(
        tester.widget<Slider>(find.byKey(const Key('strength_cap'))).onChanged,
        isNotNull,
      );
      expect(find.textContaining('模拟'), findsNothing);
      expect(find.textContaining('开发版'), findsNothing);
      expect(find.textContaining('不是毫安值'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      physical.dispose();
      library.dispose();
      s.dispose();
    },
  );

  testWidgets('user connection panel forces DG-LAB and hides test endpoints', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConnectionPanel(developerAccess: false),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('gateway_endpoint')), findsNothing);
    expect(find.textContaining('Intiface'), findsNothing);
    expect(find.textContaining('开发版'), findsNothing);
    expect(find.textContaining('DG-LAB 4 负责蓝牙连接'), findsOneWidget);
    expect(find.text('连接服务'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
