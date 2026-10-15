import 'package:haptics_lab/app_access.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/warm_playback.dart';
import 'package:haptics_lab/warm_theme.dart';
import 'package:haptics_lab/warm_splash.dart';
import 'package:haptics_lab/warm_library.dart';
import 'package:haptics_lab/warm_wave_pages.dart';
import 'package:haptics_lab/venice_wave_session.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/api_model_provider.dart';

import 'warm_test_helpers.dart';

class DelayedChat extends ModelProvider {
  final pending = Completer<ModelReply>();
  int calls = 0;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) {
    calls++;
    return calls == 1
        ? pending.future
        : Future.value(const ModelReply('收到，谢谢。', {}));
  }
}

void main() {
  testWidgets(
    'only active playback moves; library remains static; stop freezes unlimited playback',
    (tester) async {
      var now = DateTime(2026);
      final session = VeniceWaveSession(now: () => now);
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              WarmPlayback(session: session),
              WarmWavePlot(session.wave.levels),
            ],
          ),
        ),
      );
      expect(find.byKey(const Key('active_wave_plot')), findsNothing);
      session.grant();
      await tester.pump();
      PlaybackPainter painter() =>
          tester
                  .widget<CustomPaint>(
                    find.byKey(const Key('active_wave_plot')),
                  )
                  .painter!
              as PlaybackPainter;
      final first = painter().phase;
      now = now.add(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 50));
      expect(painter().phase, isNot(first));
      expect(find.byType(WarmWavePlot), findsOneWidget);
      session.selectIdle(
        session.waves.last.id,
      ); // Cannot silently swap an active session.
      session.stop();
      await tester.pump();
      expect(find.byKey(const Key('active_wave_plot')), findsNothing);
      session.grant(toDevice: true);
      await tester.pump();
      now = now.add(const Duration(seconds: 121));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('active_wave_plot')), findsOneWidget);
      session.stop();
      await tester.pump();
      expect(find.byKey(const Key('active_wave_plot')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'candidate manager browses full library and saves selected scope',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = VeniceWaveSession();
      final library = WarmLibrary(session);
      await tester.pumpWidget(
        MaterialApp(
          theme: warmTheme(),
          home: Scaffold(
            body: WarmWaveLibraryPage(library: library, onSelected: () {}),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('manage_candidates')));
      await tester.pumpAndSettle();
      expect(find.text('管理 AI 可用波形'), findsOneWidget);
      expect(
        find.byKey(ValueKey('candidate_${session.waves.last.id}')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(ValueKey('candidate_${session.waves.last.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save_candidates')));
      await settleWarm(tester);
      expect(session.candidates, {session.waves.first.id});
      session.grant();
      await tester.pump();
      await tester.tap(find.byKey(const Key('manage_candidates')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save_candidates')))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      library.dispose();
      session.dispose();
    },
  );
  testWidgets(
    'cold splash finishes after two seconds and resume does not replay',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: WarmSplash(child: Text('主页面'))),
      );
      expect(find.byKey(const Key('warm_splash')), findsOneWidget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1900));
      expect(find.text('主页面'), findsNothing);
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      expect(find.text('主页面'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const Key('warm_splash')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'sent message appears before reply and failed request retries only once',
    (tester) async {
      final chat = DelayedChat();
      await tester.pumpWidget(
        MaterialApp(
          home: VeniceChatPage(
            role: AppRole.administrator,
            enableDialogueGuidance: false,
            loadKey: () async => 'fixture',
            chatFactory: (_, _) => chat,
          ),
        ),
      );
      await settleWarm(tester);
      await tapWarm(tester, 'venice_funded');
      await tapWarm(tester, 'nav_chat');
      await tester.enterText(find.byKey(const Key('venice_message')), '测试即时消息');
      await tester.tap(find.byKey(const Key('venice_send')));
      await tester.pump();
      expect(
        find
            .byType(SelectableText)
            .evaluate()
            .where((e) => (e.widget as SelectableText).data == '测试即时消息'),
        hasLength(1),
      );
      chat.pending.completeError(const ModelServiceException('测试网络失败'));
      await settleWarm(tester);
      expect(find.byKey(const Key('retry_message')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('retry_message')));
      await tester.tap(find.byKey(const Key('retry_message')));
      await settleWarm(tester);
      expect(chat.calls, 2);
      expect(find.byKey(const Key('retry_message')), findsNothing);
      expect(
        find
            .byType(SelectableText)
            .evaluate()
            .where((e) => (e.widget as SelectableText).data == '测试即时消息'),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
