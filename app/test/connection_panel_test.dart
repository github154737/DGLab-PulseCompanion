import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/connection_panel.dart';
import 'package:haptics_lab/device_gateway.dart';

class ControlledGateway extends IntifaceGateway {
  final connected = Completer<void>(), reading = Completer<void>();
  final updates = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => updates.stream;
  @override
  Future<void> connect(Uri endpoint) async {
    await connected.future;
    status = '测试连接就绪';
  }

  @override
  Future<void> refresh() => reading.future;
  @override
  Future<void> close() async {
    if (!updates.isClosed) await updates.close();
  }
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final oldOperation in ['connect', 'refresh']) {
    testWidgets(
      'late $oldOperation cannot overwrite a replacement connection',
      (tester) async {
        tester.view.physicalSize = const Size(600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final old = ControlledGateway(), next = ControlledGateway();
        var count = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ConnectionPanel(
                createGateway: (_) => count++ == 0 ? old : next,
              ),
            ),
          ),
        );
        await tester.tap(find.text('连接服务'));
        await tester.pump();
        if (oldOperation == 'refresh') {
          old.connected.complete();
          await tester.pump();
          await tester.tap(find.text('刷新设备'));
          await tester.pump();
        }
        await tester.tap(find.text('断开服务'));
        await tester.pump();
        await tester.tap(find.text('连接服务'));
        await tester.pump();
        if (oldOperation == 'connect') {
          old.connected.complete();
        } else {
          old.reading.completeError(StateError('old request failed'));
        }
        await tester.pump();
        final refresh = find.widgetWithText(OutlinedButton, '刷新设备');
        expect(tester.widget<OutlinedButton>(refresh).onPressed, isNull);
        expect(find.textContaining('读取失败'), findsNothing);
        next.connected.complete();
        await tester.pump();
        expect(tester.widget<OutlinedButton>(refresh).onPressed, isNotNull);
        expect(find.text('测试连接就绪'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('remote disconnect immediately allows a new connection', (
    tester,
  ) async {
    final g = ControlledGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ConnectionPanel(createGateway: (_) => g)),
      ),
    );
    await tester.tap(find.text('连接服务'));
    g.connected.complete();
    await tester.pump();
    g.status = '连接已断开';
    await g.close();
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '连接服务'))
          .onPressed,
      isNotNull,
    );
    expect(find.text('断开服务'), findsNothing);
    expect(find.text('连接已断开'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
