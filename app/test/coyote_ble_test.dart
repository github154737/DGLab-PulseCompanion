import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/coyote_ble.dart';
import 'package:haptics_lab/coyote_ble_panel.dart';
import 'package:haptics_lab/physical_output.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/coyote');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Map<String, dynamic> state(String phase, {int generation = 3}) => {
    'state': phase,
    'generation': generation,
    'status': phase,
    'id': 'test-device',
    'name': '郊狼 3.0',
    'a': 0,
    'b': 0,
    'scanning': false,
  };
  Map<String, dynamic> output({
    double a = .1,
    String frame = '1414141432323232',
  }) => {
    'phase': 'playing',
    'device': {'id': 'sim_dglab'},
    'remaining_ms': 10000,
    'dglab_output': [
      {'frame': frame, 'strength_scale': a},
      {'frame': frame, 'strength_scale': .1},
    ],
  };
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('physical BLE binding, grant, feed and acknowledged stop', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'arm' => state('armed'),
        'stop' => state('ready'),
        _ => null,
      };
    });
    final ble = CoyoteBle(channel: channel)..accept(state('ready'));
    final p = PhysicalOutput();
    await p.bindBle(ble);
    expect(p.canArm, true);
    expect(p.armed, false);
    await p.arm();
    p.consume(output());
    await Future<void>.delayed(Duration.zero);
    final feed = calls.lastWhere((c) => c.method == 'feed');
    expect(feed.arguments['a'], 2);
    expect(feed.arguments['generation'], 3);
    await p.stop();
    expect(p.armed, false);
    expect(p.unknown, false);
    final count = calls.where((c) => c.method == 'feed').length;
    p.consume(output());
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.method == 'feed').length, count);
    await p.release();
    p.dispose();
    ble.dispose();
  });
  test('malformed and non-finite targets never reach native feed', () async {
    var feeds = 0;
    messenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'feed') feeds++;
      return c.method == 'arm' ? state('armed') : state('ready');
    });
    final ble = CoyoteBle(channel: channel);
    await ble.arm([20, 20]);
    await expectLater(
      ble.feed(output(a: double.nan), [20, 20]),
      throwsFormatException,
    );
    await expectLater(
      ble.feed(output(frame: 'oops'), [20, 20]),
      throwsFormatException,
    );
    await expectLater(ble.feed(output(a: 2), [20, 20]), throwsFormatException);
    expect(feeds, 0);
    ble.dispose();
  });
  test(
    'native fault revokes authority, cannot rearm until confirmed reset',
    () async {
      var stopping = false;
      messenger.setMockMethodCallHandler(channel, (c) async {
        if (c.method == 'stop' && stopping) {
          throw PlatformException(code: 'lost');
        }
        return c.method == 'arm' ? state('armed') : state('ready');
      });
      final ble = CoyoteBle(channel: channel)..accept(state('ready'));
      final p = PhysicalOutput();
      var faults = 0;
      p.onFault = () => faults++;
      await p.bindBle(ble);
      await p.arm();
      stopping = true;
      ble.accept(state('disconnected'));
      expect(p.armed, false);
      expect(p.unknown, true);
      expect(p.canArm, false);
      expect(faults, 1);
      await expectLater(p.arm(), throwsStateError);
      ble.accept(state('ready', generation: 5));
      expect(p.canArm, true);
      expect(p.armed, false);
      stopping = false;
      await p.release();
      p.dispose();
      ble.dispose();
    },
  );
  test('stop racing arm cannot authorize a late completion', () async {
    final late = Completer<Map<String, dynamic>>();
    messenger.setMockMethodCallHandler(
      channel,
      (c) async => c.method == 'arm' ? late.future : state('ready'),
    );
    final ble = CoyoteBle(channel: channel)..accept(state('ready'));
    final p = PhysicalOutput();
    await p.bindBle(ble);
    final arming = p.arm();
    final rejected = expectLater(arming, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    await p.stop();
    late.complete(state('armed'));
    await rejected;
    expect(p.armed, false);
    await p.release();
    p.dispose();
    ble.dispose();
  });
  test('at most one pending feed and stop invalidates grant', () async {
    final pending = Completer<void>();
    var feeds = 0;
    messenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'feed') {
        feeds++;
        await pending.future;
        return null;
      }
      return c.method == 'arm' ? state('armed') : state('ready');
    });
    final ble = CoyoteBle(channel: channel)..accept(state('ready'));
    final p = PhysicalOutput();
    await p.bindBle(ble);
    await p.arm();
    for (var i = 0; i < 20; i++) {
      p.consume(output());
    }
    await Future<void>.delayed(Duration.zero);
    expect(feeds, 1);
    await p.stop();
    pending.complete();
    await Future<void>.delayed(Duration.zero);
    await expectLater(ble.feed(output(), [20, 20]), throwsStateError);
    await p.release();
    p.dispose();
    ble.dispose();
  });
  testWidgets('permission denial visible and no scanning or output', (
    tester,
  ) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c.method);
      return c.method == 'permissions' ? false : null;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CoyoteBlePanel(
              createClient: () => CoyoteBle(channel: channel),
              onSelected: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('ble_scan')));
    await tester.pumpAndSettle();
    expect(find.textContaining('未授予蓝牙权限'), findsOneWidget);
    expect(calls, ['permissions']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets('empty scan explains no device and keeps selection unavailable', (
    tester,
  ) async {
    late CoyoteBle ble;
    messenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'permissions') return true;
      if (c.method == 'scan') {
        ble.accept({
          ...state('disconnected'),
          'devices': [],
          'status': '未找到设备',
        });
      }
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CoyoteBlePanel(
              createClient: () => ble = CoyoteBle(channel: channel),
              onSelected: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('ble_scan')));
    await tester.pumpAndSettle();
    expect(find.text('未找到设备'), findsOneWidget);
    expect(find.byKey(const Key('ble_select')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
