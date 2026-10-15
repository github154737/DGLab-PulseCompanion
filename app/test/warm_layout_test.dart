import 'package:haptics_lab/app_access.dart';

import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_wave_session.dart';
import 'package:haptics_lab/warm_library.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/chat_context.dart';

import 'warm_test_helpers.dart';

class NameChat extends ModelProvider {
  String? name;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) async {
    name = context.aiName;
    return const ModelReply('收到你的消息。', {});
  }
}

void main() {
  for (final entry in [
    (const Size(320, 640), 1.0),
    (const Size(360, 800), 1.3),
    (const Size(412, 915), 2.0),
    (const Size(844, 390), 1.0),
    (const Size(800, 1280), 1.0),
  ]) {
    testWidgets('warm pages fit ${entry.$1} at text scale ${entry.$2}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(entry.$1);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(entry.$2)),
            child: child!,
          ),
          home: VeniceChatPage(
            role: AppRole.administrator,
            enableDialogueGuidance: false,
            loadKey: () async => 'fixture',
          ),
        ),
      );
      await settleWarm(tester);
      expect(tester.takeException(), isNull);
      for (final tab in ['nav_interaction', 'nav_mine', 'nav_chat']) {
        await tapWarm(tester, tab);
        expect(tester.takeException(), isNull, reason: tab);
      }
      if (find.byKey(const Key('expand_chat_control')).evaluate().isNotEmpty) {
        await tester.ensureVisible(
          find.byKey(const Key('expand_chat_control')),
        );
        await tester.tap(find.byKey(const Key('expand_chat_control')));
        await settleWarm(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: 'expanded quick controls',
        );
        await tester.tap(find.byKey(const Key('expand_chat_control')));
        await settleWarm(tester);
      }
      await tester.ensureVisible(find.byKey(const Key('show_recording')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('show_recording')));
      await settleWarm(tester);
      expect(tester.takeException(), isNull, reason: 'recorder panel');
      await tester.enterText(
        find.byKey(const Key('venice_message')),
        '键盘打开后的消息',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'keyboard');
      tester.view.resetViewInsets();
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('AI name saves, survives restart and reaches chat context', (
    tester,
  ) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('warm-name-test-'),
    );
    addTearDown(() => dir!.delete(recursive: true));
    final provider = NameChat();
    Widget app() => MaterialApp(
      home: VeniceChatPage(
        role: AppRole.administrator,
        enableDialogueGuidance: false,
        preferencesDirectory: dir,
        loadKey: () async => 'fixture',
        chatFactory: (_, _) => provider,
      ),
    );
    await tester.pumpWidget(app());
    await settleWarm(tester);
    await tapWarm(tester, 'edit_ai_name');
    await tester.enterText(find.byKey(const Key('ai_name_input')), '星禾');
    await tester.tap(find.byKey(const Key('save_ai_name')));
    await settleWarm(tester);
    await tapWarm(tester, 'venice_funded');
    await tapWarm(tester, 'nav_chat');
    expect(find.text('星禾'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('venice_message')), '你好');
    await tapWarm(tester, 'venice_send');
    expect(provider.name, '星禾');
    final saved = await tester.runAsync(
      () => File('${dir!.path}/warm-preferences-v1.json').readAsString(),
    );
    expect(saved, contains('星禾'));
    await tester.pumpWidget(const SizedBox());
    await settleWarm(tester);
    await tester.pumpWidget(app());
    await settleWarm(tester);
    await settleWarm(tester);
    expect(find.text('星禾'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'categories favorites and AI allowlist survive restart independently',
    (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('warm-library-test-'),
      );
      final s = VeniceWaveSession(), next = VeniceWaveSession();
      final library = WarmLibrary(s, directory: dir),
          restored = WarmLibrary(next, directory: dir);
      await tester.runAsync(() => library.restore());
      // Use an original fixture, independent of the private waveform collection.
      await tester.runAsync(
        () => library.importBytes(
          'fixture.pulse',
          utf8.encode(
            'Dungeonlab+pulse:8,1,8=0,20,0,1,1/0.00-1,25.00-0,0.00-1',
          ),
        ),
      );
      expect(s.waves.length, greaterThanOrEqualTo(3));
      final first = s.waves.first.id, imported = s.waves.last.id;
      library.favorites.add(imported);
      library.categories.add('自定义组');
      library.assignments[imported] = '自定义组';
      library.tags[imported] = ['晚间'];
      s.candidates
        ..clear()
        ..add(first);
      await tester.runAsync(() async {
        library.removeCategory('渐变呼吸');
        await library.save();
      });
      await tester.runAsync(() => restored.restore());
      expect(restored.favorites, contains(imported));
      expect(next.candidates, {first});
      expect(restored.category(next.waves.first), '未分类');
      expect(restored.assignments[imported], '自定义组');
      expect(restored.tags[imported], ['晚间']);
      expect(next.active, false);
      library.dispose();
      restored.dispose();
      s.dispose();
      next.dispose();
      await tester.runAsync(() => dir!.delete(recursive: true));
    },
  );
}
