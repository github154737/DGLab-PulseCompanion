import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/connection_panel.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/main.dart';
import 'package:haptics_lab/waveform_panel.dart';

Future<Directory> unavailableDirectory() async =>
    throw StateError('test session storage');

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  setUp(() {
    CoreBridge().call({'op': 'reset_simulation'});
    CoreBridge().call({
      'op': 'remove_waveform',
      'waveform_id': 'gentle_import',
    });
  });
  testWidgets(
    'chat strength controls continuous output and reports the actual gain',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const HapticsApp(waveformDirectory: unavailableDirectory),
      );
      await tester.tap(find.byKey(const Key('device_sim_single')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('start_experience')));
      await tester.tap(find.byKey(const Key('start_experience')));
      await tester.pump();
      expect(
        CoreBridge().call({'op': 'snapshot'})['state']['continuous'],
        true,
      );
      expect(
        CoreBridge().call({'op': 'snapshot'})['state']['phase'],
        'playing',
      );
      final stronger = find.widgetWithText(ActionChip, '强一点');
      await tester.ensureVisible(stronger);
      await tester.pump();
      await tester.tap(stronger);
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        CoreBridge().call({'op': 'snapshot'})['state']['gain_target'],
        closeTo(0.6, 1e-8),
      );
      expect(find.textContaining('50% → 60%'), findsNWidgets(2));
      expect(find.textContaining('已应用到当前仿真波形'), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('stop')));
      await tester.pump();
      expect(CoreBridge().call({'op': 'snapshot'})['state']['output'], [
        0.0,
        0.0,
      ]);
      expect(find.textContaining('授权及待处理动作已撤销'), findsOneWidget);
      expect(find.textContaining('50% → 60%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('unauthorized strength request explains why no output changed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const HapticsApp(waveformDirectory: unavailableDirectory),
    );
    await tester.tap(find.byKey(const Key('device_sim_single')));
    await tester.pump();
    final stronger = find.widgetWithText(ActionChip, '强一点');
    await tester.ensureVisible(stronger);
    await tester.pump();
    await tester.tap(stronger);
    await tester.pump(const Duration(milliseconds: 700));
    final receipt = find.descendant(
      of: find.byKey(const Key('action_receipt')),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(receipt).data, contains('尚未授权或授权已到期'));
    expect(CoreBridge().call({'op': 'snapshot'})['state']['phase'], 'ready');
    expect(CoreBridge().call({'op': 'snapshot'})['state']['gain_target'], 0.5);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'startup restore blocks authorization and import until completed',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Completer<Directory>();
      await tester.pumpWidget(
        HapticsApp(waveformDirectory: () => directory.future),
      );
      await tester.tap(find.text('设备'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('device_sim_single')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('authorize')));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('authorize')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('波形'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('import_waveform')))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('正在恢复本机波形库'), findsOneWidget);
      directory.completeError(StateError('storage unavailable'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('import_waveform')))
            .onPressed,
        isNotNull,
      );
      expect(find.textContaining('当前仅保留在会话内'), findsOneWidget);
      expect(CoreBridge().call({'op': 'snapshot'})['state']['phase'], 'ready');
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'import previews before acceptance and exposes only compatible simulation playback',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = CoreBridge();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => WaveformImportDialog(core: core),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('wave_source')),
        envelopeExample,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save_waveform')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('validate_waveform')));
      await tester.pump();
      expect(find.text('我的渐变 · 1.5 秒'), findsOneWidget);
      expect(
        (core.call({'op': 'snapshot'})['state']['waveforms'] as List).any(
          (w) => w['id'] == 'gentle_import',
        ),
        false,
      );
      await tester.tap(find.byKey(const Key('save_waveform')));
      await tester.pumpAndSettle();
      expect(
        (core.call({'op': 'snapshot'})['state']['waveforms'] as List).any(
          (w) => w['id'] == 'gentle_import',
        ),
        true,
      );
      expect(core.call({'op': 'snapshot'})['state']['phase'], 'disconnected');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      core.call({'op': 'remove_waveform', 'waveform_id': 'gentle_import'});
    },
  );
  testWidgets('desktop connect authorize play stop with the native core', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const HapticsApp(waveformDirectory: unavailableDirectory),
    );
    expect(find.text('触觉实验室'), findsOneWidget);
    await tester.tap(find.byKey(const Key('device_sim_single')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('authorize')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('soft_pulse')));
    await tester.pump();
    expect(CoreBridge().call({'op': 'snapshot'})['state']['phase'], 'playing');
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump();
    expect(CoreBridge().call({'op': 'snapshot'})['state']['phase'], 'stopped');
    expect(CoreBridge().call({'op': 'snapshot'})['state']['output'], [
      0.0,
      0.0,
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('mobile navigation keeps stop reachable and does not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const HapticsApp(waveformDirectory: unavailableDirectory),
    );
    await tester.tap(find.text('设备'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('device_sim_single')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('authorize')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('authorize')));
    await tester.pump();
    expect(
      CoreBridge().call({'op': 'snapshot'})['state']['phase'],
      'authorized',
    );
    await tester.tap(find.text('体验'));
    await tester.pump();
    expect(find.byKey(const Key('stop')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('stop during pending chat suppresses the delayed action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const HapticsApp(waveformDirectory: unavailableDirectory),
    );
    await tester.tap(find.byKey(const Key('device_sim_single')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('authorize')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('chat_input')));
    expect(
      CoreBridge().call({'op': 'snapshot'})['state']['phase'],
      'authorized',
    );
    await tester.pump();
    await tester.enterText(find.byKey(const Key('chat_input')), '柔和起伏');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('send')));
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('send'))).onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump();
    expect(CoreBridge().call({'op': 'snapshot'})['state']['pending_ai'], 1);
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump(const Duration(milliseconds: 800));
    expect(CoreBridge().call({'op': 'snapshot'})['state']['phase'], 'stopped');
    expect(CoreBridge().call({'op': 'snapshot'})['state']['output'], [
      0.0,
      0.0,
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('responsive layout preserves the active connection panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const HapticsApp(waveformDirectory: unavailableDirectory),
    );
    await tester.pump();
    final panel = tester.state(find.byType(ConnectionPanel));
    await tester.ensureVisible(find.byKey(const Key('gateway_endpoint')));
    await tester.enterText(
      find.byKey(const Key('gateway_endpoint')),
      'ws://localhost:12346',
    );
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.tap(find.text('设备'));
    await tester.pump();
    expect(tester.state(find.byType(ConnectionPanel)), same(panel));
    await tester.ensureVisible(find.byKey(const Key('gateway_endpoint')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('gateway_endpoint')))
          .controller!
          .text,
      'ws://localhost:12346',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
