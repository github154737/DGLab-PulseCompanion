import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/simulation_session.dart';

void main() {
  late CoreBridge core;
  late SimulationSession session;
  late DateTime now;
  late List<Map<String, dynamic>> receipts;
  setUp(() {
    core = CoreBridge();
    core.call({'op': 'reset_simulation'});
    now = DateTime(2026);
    receipts = [];
    session = SimulationSession(core.call, receipts.add, now: () => now);
  });
  tearDown(() => session.stop());
  int ticket() => core.call({'op': 'begin_ai'})['result']['ticket'] as int;
  test('explicit scope accepts bounded plan, clamps gain and returns actual receipts', () {
    expect(session.grant(seconds: 60, ceiling: 0.5)['ok'], true);
    final result = session.schedule([
      {'after_ms': 0, 'action': 'increase'},
      {'after_ms': 3000, 'action': 'gentle_wave'},
    ], ticket());
    expect(result['scheduled'], 2);
    expect(result['executed'], false);
    session.tick();
    expect(receipts.single['gain_target'], 0.5);
    now = now.add(const Duration(seconds: 3));
    session.tick();
    expect(receipts.last['action'], 'gentle_wave');
    expect(receipts.last['ok'], true);
  });
  test(
    'feedback preempts future steps; replay and post-stop plan cannot execute',
    () {
      session.grant();
      final t = ticket();
      expect(
        session.schedule([
          {'after_ms': 3000, 'action': 'increase'},
        ], t)['ok'],
        true,
      );
      expect(
        session.schedule([
          {'after_ms': 0, 'action': 'increase'},
        ], t)['ok'],
        false,
      );
      session.feedback();
      expect(session.planningEnabled, false);
      now = now.add(const Duration(seconds: 4));
      session.tick();
      expect(receipts, isEmpty);
      final stale = ticket();
      session.stop();
      expect(
        session.schedule([
          {'after_ms': 0, 'action': 'increase'},
        ], stale)['ok'],
        false,
      );
      expect(core.call({'op': 'snapshot'})['state']['phase'], 'stopped');
    },
  );
  test('invalid and expired plans are rejected without partial execution', () {
    session.grant(seconds: 5);
    expect(
      session.schedule([
        {'after_ms': 0, 'action': 'increase'},
        {'after_ms': 1000, 'action': 'increase'},
      ], ticket())['ok'],
      false,
    );
    expect(
      session.schedule([
        {'after_ms': 6000, 'action': 'increase'},
      ], ticket())['ok'],
      false,
    );
    expect(session.queued, 0);
    now = now.add(const Duration(seconds: 6));
    session.tick();
    expect(session.active, false);
    expect(receipts, isEmpty);
  });
}
