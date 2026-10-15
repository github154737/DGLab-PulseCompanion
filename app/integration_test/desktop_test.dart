import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/main.dart';
import 'package:integration_test/integration_test.dart';

Future<Directory> noStorage() async => throw StateError('isolated UI test');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets('native desktop chat with accessibility and repeated updates', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var semanticsDisposed = false;
    addTearDown(() {
      if (!semanticsDisposed) semantics.dispose();
    });
    final core = CoreBridge();
    core.call({'op': 'reset_simulation'});
    await tester.pumpWidget(const HapticsApp(waveformDirectory: noStorage));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device_sim_dglab')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('start_experience')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start_experience')));
    await tester.pump();
    expect(core.call({'op': 'snapshot'})['state']['phase'], 'playing');
    final initialGain = core.call({'op': 'snapshot'})['state']['gain_target'];
    for (var round = 0; round < 12; round++) {
      final action = find.widgetWithText(
        ActionChip,
        round.isEven ? '强一点' : '弱一点',
      );
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      expect(action.hitTestable(), findsOneWidget);
      await tester.tap(action);
      await tester.pumpAndSettle();
      for (var wait = 0; wait < 20; wait++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (tester
                .widget<IconButton>(find.byKey(const Key('send')))
                .onPressed !=
            null) {
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 1100));
      if (round == 0) {
        final actual = core.call({'op': 'snapshot'})['state'];
        expect(
          actual['gain_target'],
          greaterThan(initialGain),
          reason:
              'State: $actual; receipts: ${find.byKey(const Key('message_receipt')).evaluate().map((e) => e.widget).toList()}',
        );
      }
      expect(find.byKey(const Key('message_receipt')), findsWidgets);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump();
    final stopped = core.call({'op': 'snapshot'})['state'];
    expect(stopped['phase'], 'stopped');
    expect(stopped['output'], [0.0, 0.0]);
    binding.reportData = {
      'verified': {
        'platform': 'Windows native desktop',
        'simulation_only': true,
        'semantics_enabled': true,
        'conversation_updates': 12,
        'stronger_increased_gain': true,
        'stop_zeroed_output': true,
      },
    };
    semantics.dispose();
    semanticsDisposed = true;
    await tester.pumpWidget(const SizedBox());
  });
}
