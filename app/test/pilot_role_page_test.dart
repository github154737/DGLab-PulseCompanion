import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/app_access.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/network_diagnostics.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_wave_session.dart';

import 'control_context_page_test.dart' show Player;
import 'warm_test_helpers.dart' show settleWarm;

class RoleProvider extends ModelProvider {
  RoleProvider(this.answer);
  final Future<String> Function() answer;
  int calls = 0, cancellations = 0;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) async {
    calls++;
    return ModelReply(await answer(), {});
  }

  @override
  void cancel() => cancellations++;
}

Future<dynamic> mountRolePage(
  WidgetTester tester, {
  AppRole role = AppRole.user,
  VoidCallback? onLogout,
  RoleProvider? chat,
  RoleProvider? planner,
  RoleProvider? guidance,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 2400));
  final directory = Directory.systemTemp.createTempSync('pilot-role-page-');
  await tester.pumpWidget(
    MaterialApp(
      home: VeniceChatPage(
        role: role,
        onLogout: onLogout,
        loadKey: () async => 'offline-fixture',
        preferencesDirectory: directory,
        enableDialogueGuidance: guidance != null,
        guidanceFactory: guidance == null ? null : (_, _) => guidance,
        plannerFactory: (_, _) =>
            planner ?? RoleProvider(() async => '{"action":"hold"}'),
        chatFactory: (_, _) => chat ?? RoleProvider(() async => '这是一条离线测试回复。'),
        speechPlayer: Player(),
      ),
    ),
  );
  await settleWarm(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  final dynamic state = tester.state(find.byType(VeniceChatPage));
  state.library.autoSpeak = false;
  return state;
}

void main() {
  test('direct chat page defaults to ordinary user permissions', () {
    expect(const VeniceChatPage().role, AppRole.user);
  });

  testWidgets(
    'user settings omit diagnostics, model controls, and test details',
    (tester) async {
      final dynamic state = await mountRolePage(tester, onLogout: () {});
      state.selectPage(2);
      await tester.pumpAndSettle();
      expect(find.text('我的'), findsWidgets);
      expect(find.byKey(const Key('connection_diagnostics')), findsNothing);
      expect(find.text('控制与对话诊断'), findsNothing);
      expect(find.text('模型与服务'), findsNothing);
      expect(find.byKey(const Key('venice_key_status')), findsNothing);
      expect(find.byKey(const Key('venice_reload_key')), findsNothing);
      expect(find.byKey(const Key('venice_model')), findsNothing);
      expect(find.textContaining('模拟'), findsNothing);
      expect(find.textContaining('密钥'), findsNothing);
      expect(find.textContaining('xAI TTS'), findsNothing);
      expect(find.byKey(const Key('auto_speak')), findsOneWidget);
      expect(find.byKey(const Key('speech_voice')), findsOneWidget);
      expect(find.byKey(const Key('pilot_logout')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('administrator retains diagnostics, models, and simulation', (
    tester,
  ) async {
    final dynamic state = await mountRolePage(
      tester,
      role: AppRole.administrator,
      onLogout: () {},
    );
    state.selectPage(2);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('connection_diagnostics')), findsOneWidget);
    final models = find.text('模型与服务');
    await tester.ensureVisible(models);
    await tester.tap(models);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('venice_reload_key')), findsOneWidget);
    expect(find.byKey(const Key('venice_model')), findsOneWidget);
    state.selectPage(0);
    await tester.pumpAndSettle();
    expect(find.text('开始模拟'), findsOneWidget);
    final VeniceWaveSession session = state.waves;
    expect(session.allowSimulation, true);
  });

  testWidgets('user interaction cannot enter simulation through the session', (
    tester,
  ) async {
    final dynamic state = await mountRolePage(tester);
    state.selectPage(0);
    await tester.pumpAndSettle();
    final VeniceWaveSession session = state.waves;
    expect(session.allowSimulation, false);
    expect(session.snapshot()['mode'], 'device');
    expect(find.textContaining('模拟'), findsNothing);
    expect(() => session.grant(), throwsStateError);
    expect(session.active, false);
    expect(find.byKey(const Key('venice_wave_grant')), findsOneWidget);
    await tester.tap(find.byKey(const Key('venice_wave_grant')));
    await tester.pumpAndSettle();
    expect(session.active, false);
    expect(find.text('连接服务'), findsOneWidget);
    expect(find.byKey(const Key('gateway_endpoint')), findsNothing);
  });

  testWidgets('direct diagnostic route denies access before displaying logs', (
    tester,
  ) async {
    NetworkTrace.clear();
    NetworkTrace('控制轮次').mark('ROLE_LOG_MARKER_ORDINARY');
    expect(NetworkTrace.report, contains('ROLE_LOG_MARKER_ORDINARY'));
    await tester.pumpWidget(
      const MaterialApp(home: ConnectionDiagnostics(apiKey: 'offline-fixture')),
    );
    expect(find.textContaining('ROLE_LOG_MARKER_ORDINARY'), findsNothing);
    expect(find.text('复制诊断'), findsNothing);
    expect(find.text('刷新记录'), findsNothing);
    expect(find.text('清空，开始新测试'), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    await tester.pumpWidget(
      const MaterialApp(
        home: ConnectionDiagnostics(
          apiKey: 'offline-fixture',
          developerAccess: true,
        ),
      ),
    );
    expect(find.textContaining('ROLE_LOG_MARKER_ORDINARY'), findsOneWidget);
    expect(find.text('复制诊断'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    NetworkTrace.clear();
  });

  for (final phase in ['planning', 'chat']) {
    testWidgets(
      'logout cancels $phase and stops output before invoking callback',
      (tester) async {
        final advice = jsonEncode({
          'intent_summary': '用户希望继续聊天',
          'reply_focus': ['回应当前话题'],
          'context_anchor': '',
          'ask_clarification': false,
        });
        final guideResult = Completer<String>();
        final planResult = Completer<String>();
        final chatResult = Completer<String>();
        final guide = RoleProvider(
          () => phase == 'planning' ? guideResult.future : Future.value(advice),
        );
        final planner = RoleProvider(
          () => phase == 'planning'
              ? planResult.future
              : Future.value('{"action":"hold"}'),
        );
        final chat = RoleProvider(() => chatResult.future);
        var callbacks = 0;
        late VeniceWaveSession session;
        final dynamic state = await mountRolePage(
          tester,
          role: AppRole.administrator,
          guidance: guide,
          planner: planner,
          chat: chat,
          onLogout: () {
            expect(session.active, false);
            expect(session.strength, [0, 0]);
            callbacks++;
          },
        );
        session = state.waves;
        session.grant();
        session.strength[0] = 2;
        state.funded = true;
        state.input.text = '聊一聊明天的计划';
        final pending = state.send() as Future<bool>;
        await tester.pump();
        await tester.pump();
        expect(guide.calls, 1);
        expect(planner.calls, 1);
        if (phase == 'chat') expect(chat.calls, 1);
        state.selectPage(2);
        await tester.pump();
        final logout = find.byKey(const Key('pilot_logout'));
        await tester.ensureVisible(logout);
        await tester.tap(logout);
        await tester.pump();
        await tester.pump();
        expect(callbacks, 1);
        if (phase == 'planning') {
          expect(planner.cancellations, greaterThan(0));
          expect(guide.cancellations, greaterThan(0));
          guideResult.complete(advice);
          planResult.complete('{"action":"hold"}');
        } else {
          expect(chat.cancellations, greaterThan(0));
          chatResult.complete('ROLE_LATE_REPLY_MUST_NOT_APPEAR');
        }
        await tester.pump();
        await tester.pump();
        expect(await pending, false);
        expect(session.active, false);
        expect(session.strength, [0, 0]);
        expect(
          find.textContaining('ROLE_LATE_REPLY_MUST_NOT_APPEAR'),
          findsNothing,
        );
        if (phase == 'planning') expect(chat.calls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
