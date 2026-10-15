import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/connection_panel.dart';
import 'package:haptics_lab/device_gateway.dart';
import 'package:haptics_lab/dglab_pairing.dart';
import 'package:haptics_lab/physical_output.dart';

class PairingGateway extends DglabV4Gateway {
  final updates = StreamController<void>.broadcast();
  bool closed = false;
  int refreshes = 0;
  @override
  Future<void> refresh() async {
    refreshes++;
  }

  @override
  Stream<void> get changes => updates.stream;
  @override
  Future<void> connect(Uri endpoint) async {
    pairingUri = Uri.https('dungeon-lab.cn', '/s/', {
      'v': '1',
      'action': 'socket',
      'url': endpoint
          .replace(queryParameters: {'tid': 'test-session'})
          .toString(),
    });
    status = '等待 DG-LAB 4 APP 配对';
  }

  @override
  Future<void> close() async {
    closed = true;
    pairingUri = null;
    if (!updates.isClosed) await updates.close();
    await super.close();
  }
}

void main() {
  test(
    'direct app URI preserves nested query and session without double encoding',
    () {
      final ws = Uri.parse('wss://trex.dungeon-lab.cn/v4?tid=session-123');
      final web = Uri.https('dungeon-lab.cn', '/s/', {
        'v': '1',
        'action': 'socket',
        'url': ws.toString(),
      });
      final app = dglabAppPairingUri(web);
      expect(app.toString(), 'dglab4://s?${web.query}');
      expect(
        Uri.parse(app.queryParameters['url']!).queryParameters['tid'],
        'session-123',
      );
      expect(
        () => dglabAppPairingUri(
          Uri.parse('https://example.com/s/?action=socket'),
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'discovery requires explicit selection; selection enables arming without output',
    (tester) async {
      tester.view.physicalSize = const Size(430, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final g = PairingGateway(), p = PhysicalOutput();
      const d = RemoteDevice(
        id: 'phone:slot',
        name: 'COYOTE',
        kind: 'COYOTE_030',
        channels: 2,
        details: {
          'slotState': {'hasDevice': true},
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ListenableBuilder(
                listenable: p,
                builder: (context, _) => ConnectionPanel(
                  initialKind: 'dglab_v4',
                  createGateway: (_) => g,
                  selectedDeviceId: p.device?.id,
                  onDeviceSelected: p.bind,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('连接服务'));
      await tester.pumpAndSettle();
      g.deviceMap[d.id] = d;
      g.updates.add(null);
      await tester.pumpAndSettle();
      expect(p.canArm, false);
      final select = find.byKey(const ValueKey('select_device_phone:slot'));
      await tester.ensureVisible(select);
      await tester.tap(select);
      await tester.pumpAndSettle();
      expect(p.canArm, true);
      expect(p.armed, false);
      expect(find.text('已选择'), findsOneWidget);
      expect(tester.widget<FilledButton>(select).onPressed, isNull);
      // Do not use a network-backed stop on this UI-only gateway fixture.
      p.gateway = null;
      p.device = null;
      await tester.pumpWidget(const SizedBox());
      p.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  for (final opened in [true, false]) {
    testWidgets(
      'same-phone pairing launch $opened keeps connection until explicit stop',
      (tester) async {
        tester.view.physicalSize = const Size(430, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final g = PairingGateway(), stop = ValueNotifier<int>(0);
        final activity = <bool>[];
        Uri? launched;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ConnectionPanel(
                  initialKind: 'dglab_v4',
                  createGateway: (_) => g,
                  disconnectSignal: stop,
                  onConnectionActivity: (active) async {
                    activity.add(active);
                    return true;
                  },
                  openPairingLink: (uri) async {
                    launched = uri;
                    return opened;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('连接服务'));
        await tester.pumpAndSettle();
        expect(activity, [true]);
        final pair = find.byKey(const Key('open_dglab_pairing'));
        await tester.ensureVisible(pair);
        await tester.tap(pair);
        await tester.pumpAndSettle();
        expect(launched!.scheme, 'dglab4');
        expect(launched!.query, g.pairingUri!.query);
        expect(
          Uri.parse(launched!.queryParameters['url']!).queryParameters['tid'],
          'test-session',
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(g.closed, false);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(g.refreshes, greaterThanOrEqualTo(1));
        expect(
          find.textContaining(opened ? '打开页面不代表配对成功' : '未能打开配对页面'),
          findsOneWidget,
        );
        stop.value++;
        await tester.pump(const Duration(milliseconds: 20));
        // Stream cancellation may complete in the root zone, outside fake time.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
        expect(g.closed, true);
        expect(activity, [true, false]);
        expect(pair, findsNothing);
        await tester.pumpWidget(const SizedBox());
        stop.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('background preparation failure does not expose pairing link', (
    tester,
  ) async {
    final g = PairingGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionPanel(
            createGateway: (_) => g,
            initialKind: 'dglab_v4',
            onConnectionActivity: (_) async => false,
          ),
        ),
      ),
    );
    await tester.tap(find.text('连接服务'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_dglab_pairing')), findsNothing);
    expect(find.textContaining('后台连接服务未启动'), findsOneWidget);
    expect(g.closed, true);
    await tester.pumpWidget(const SizedBox());
  });
}
