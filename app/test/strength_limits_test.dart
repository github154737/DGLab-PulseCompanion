import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/physical_output.dart';
import 'package:haptics_lab/venice_wave_session.dart';
import 'package:haptics_lab/warm_library.dart';
import 'package:haptics_lab/warm_interaction.dart';
import 'package:haptics_lab/warm_strength_limits.dart';

import 'warm_test_helpers.dart';

Map<String, dynamic> command(VeniceWaveSession s, int a, int b) => {
  'action': 'set',
  'a': a,
  'b': b,
  'waveform_id': s.selected,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'configured increase/cap are enforced and reductions remain unrestricted',
    () {
      final s = VeniceWaveSession(now: () => DateTime(2026));
      expect(s.setLimits(cap: 30, maxIncrease: 8, manualStep: 3), true);
      final stale = s.epoch;
      s.grant();
      expect(s.apply(command(s, 8, 8), stale), contains('过期'));
      s.apply(command(s, 8, 8), s.epoch);
      expect(s.strength, [8, 8]);
      expect(s.apply(command(s, 17, 8), s.epoch), contains('单步增加 8'));
      expect(s.strength, [8, 8]);
      for (final target in [16, 24, 30]) {
        s.apply(command(s, target, target), s.epoch);
      }
      expect(s.strength, [30, 30]);
      expect(s.apply(command(s, 31, 30), s.epoch), contains('上限 30'));
      s.apply(command(s, 0, 0), s.epoch);
      expect(s.strength, [0, 0]);
      expect(s.snapshot()['max_increase_per_turn'], 8);
      expect(s.setLimits(cap: 40, maxIncrease: 10, manualStep: 1), true);
      expect(s.cap, 40);
      s.stop();
      s.grant(toDevice: true);
      expect(s.setLimits(cap: 45, maxIncrease: 10, manualStep: 1), false);
      expect(s.deadline, isNull);
      expect(s.physicalState()['remaining_ms'], 1000);
      expect(s.strength, [0, 0]);
      s.stop();
      s.dispose();
    },
  );

  test(
    'invalid settings fail atomically; manual buttons use chosen step and cap',
    () {
      final s = VeniceWaveSession(now: () => DateTime(2026));
      expect(s.setLimits(cap: 51, maxIncrease: 5, manualStep: 1), false);
      expect(s.setLimits(cap: 20, maxIncrease: 0, manualStep: 1), false);
      expect(s.setLimits(cap: 20, maxIncrease: 3, manualStep: 4), false);
      expect(s.cap, 20);
      expect(s.setLimits(cap: 7, maxIncrease: 3, manualStep: 3), true);
      s.grant();
      for (var i = 0; i < 3; i++) {
        adjustWarmChannel(s, 0, s.manualStep);
      }
      expect(s.strength, [7, 0]);
      adjustWarmChannel(s, 0, -s.manualStep);
      expect(s.strength, [4, 0]);
      s.stop();
      s.dispose();
    },
  );

  test('limits survive restart but do not restore authorization', () async {
    final dir = await Directory.systemTemp.createTemp('strength-prefs-');
    addTearDown(() => dir.delete(recursive: true));
    final s = VeniceWaveSession(now: () => DateTime(2026));
    final library = WarmLibrary(s, directory: dir);
    await library.restore();
    s.setLimits(cap: 35, maxIncrease: 9, manualStep: 2);
    await library.save();
    final restored = VeniceWaveSession();
    final next = WarmLibrary(restored, directory: dir);
    await next.restore();
    expect(
      [restored.cap, restored.maxIncrease, restored.manualStep],
      [35, 9, 2],
    );
    expect(restored.active, false);
    expect(restored.strength, [0, 0]);
    final file = File('${dir.path}/warm-preferences-v1.json');
    await file.writeAsString(
      jsonEncode({
        'strengthLimits': {'cap': 999, 'maxIncrease': 0, 'manualStep': -1},
      }),
    );
    final badSession = VeniceWaveSession();
    final bad = WarmLibrary(badSession, directory: dir);
    await bad.restore();
    expect(
      [badSession.cap, badSession.maxIncrease, badSession.manualStep],
      [20, 5, 1],
    );
    for (final l in [library, next, bad]) {
      l.dispose();
    }
    for (final session in [s, restored, badSession]) {
      session.dispose();
    }
  });

  testWidgets('simulation allows sliders while physical session locks edits', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('strength-sheet-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = VeniceWaveSession(now: () => DateTime(2026));
    final lib = WarmLibrary(s, directory: dir)..ready = true;
    final physical = PhysicalOutput();
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showStrengthLimits(context, lib, physical),
              child: const Text('设置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    void slide(String key, double value) =>
        tester.widget<Slider>(find.byKey(Key(key))).onChanged!(value);
    slide('strength_cap', 33);
    await tester.pump();
    slide('strength_increase', 7);
    await tester.pump();
    slide('strength_manual_step', 2);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('save_strength_limits')));
    await tester.tap(find.byKey(const Key('save_strength_limits')));
    await settleWarm(tester);
    expect(find.byType(StrengthLimitsSheet), findsNothing);
    expect([s.cap, s.maxIncrease, s.manualStep], [33, 7, 2]);
    s.grant();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Slider>(find.byKey(const Key('strength_cap'))).onChanged,
      isNotNull,
    );
    // Exercise a real gesture instead of only invoking the callback.
    await tester.drag(
      find.byKey(const Key('strength_cap')),
      const Offset(-70, 0),
    );
    await tester.pump();
    expect(
      tester.widget<Slider>(find.byKey(const Key('strength_cap'))).value,
      lessThan(33),
    );
    s.stop();
    s.grant(toDevice: true);
    await tester.pump();
    expect(
      tester.widget<Slider>(find.byKey(const Key('strength_cap'))).onChanged,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('save_strength_limits')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    s.stop();
    lib.dispose();
    s.dispose();
    physical.dispose();
  });

  test(
    'lowering a running simulation cap clamps values and expires old plans',
    () {
      final s = VeniceWaveSession()..grant();
      s.apply(command(s, 5, 4), s.epoch);
      final ticket = s.epoch;
      expect(s.setLimits(cap: 2, maxIncrease: 1, manualStep: 1), true);
      expect(s.active, true);
      expect(s.strength, [2, 2]);
      expect(s.apply(command(s, 5, 5), ticket), contains('过期'));
      expect(s.setLimits(cap: 30, maxIncrease: 5, manualStep: 1), true);
      expect(s.strength, [2, 2]);
      s.dispose();
    },
  );
}
