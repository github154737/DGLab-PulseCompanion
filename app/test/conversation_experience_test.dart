import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/main.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/model_settings.dart';
import 'package:haptics_lab/preferences_store.dart';
import 'package:haptics_lab/waveform_panel.dart';

class PendingFollowup extends ApiModelProvider {
  PendingFollowup()
    : super(endpoint: Uri.parse('https://example.com'), model: 'fixture');
  final followup = Completer<String>();
  Map<String, dynamic>? receipt;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) async => const ModelReply('', {
    'action': 'set_gain',
    'gain': 0.6,
  }, continuation: []);
  @override
  Future<String> finishToolCall(ModelReply reply, Map<String, dynamic> result) {
    receipt = result;
    return followup.future;
  }
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  setUp(() => CoreBridge().call({'op': 'reset_simulation'}));

  void size(WidgetTester tester, [bool mobile = false]) {
    tester.view.physicalSize = mobile
        ? const Size(390, 844)
        : const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('actual receipt survives stop while model followup is pending', (
    tester,
  ) async {
    size(tester);
    final provider = PendingFollowup();
    await tester.pumpWidget(
      HapticsApp(
        waveformDirectory: () async =>
            throw const FileSystemException('session only'),
        modelProviderFactory: () => provider,
      ),
    );
    await reveal(tester, find.byKey(const Key('device_sim_single')));
    await reveal(tester, find.byKey(const Key('start_experience')));
    await reveal(tester, find.widgetWithText(ActionChip, '强一点'));
    expect(provider.receipt?['ok'], true);
    expect(provider.receipt?['gain_target'], closeTo(0.6, 1e-8));
    expect(find.textContaining('50% → 60%'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump();
    expect(find.textContaining('50% → 60%'), findsOneWidget);
    expect(find.text('动作回执已保留，后续模型回复已取消。'), findsOneWidget);
    provider.followup.complete('迟到的补充回复');
    await tester.pump();
    expect(find.text('迟到的补充回复'), findsNothing);
    expect(CoreBridge().call({'op': 'snapshot'})['state']['phase'], 'stopped');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'selected imported waveform starts continuous playback and is used by chat',
    (tester) async {
      size(tester);
      final core = CoreBridge();
      for (final id in ['choice_one', 'choice_two']) {
        core.call({'op': 'remove_waveform', 'waveform_id': id});
        expect(
          core.call({
            'op': 'import_waveform',
            'source': envelopeExample
                .replaceAll('gentle_import', id)
                .replaceAll('我的渐变', id),
          })['ok'],
          true,
        );
      }
      await tester.pumpWidget(
        HapticsApp(
          waveformDirectory: () async =>
              throw const FileSystemException('session only'),
          modelProviderFactory: () =>
              const FakeModelProvider(delay: Duration.zero),
        ),
      );
      await reveal(tester, find.byKey(const Key('device_sim_single')));
      await reveal(tester, find.byKey(const Key('experience_waveform')));
      await tester.tap(find.text('导入 · choice_two').last);
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const Key('start_experience')));
      expect(core.call({'op': 'snapshot'})['state']['preset'], 'choice_two');
      await reveal(tester, find.widgetWithText(ActionChip, '播放导入波形'));
      expect(core.call({'op': 'snapshot'})['state']['preset'], 'choice_two');
      expect(core.call({'op': 'snapshot'})['state']['continuous'], true);
      await tester.tap(find.byKey(const Key('stop')));
      await tester.pump();
      core.call({'op': 'remove_waveform', 'waveform_id': 'choice_two'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const Key('experience_waveform')),
            )
            .value,
        '',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      core.call({'op': 'remove_waveform', 'waveform_id': 'choice_one'});
    },
  );

  testWidgets(
    'mobile restores saved preferences with empty key and no authorization',
    (tester) async {
      size(tester, true);
      late Directory directory;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('haptics-restore-');
        final config = ModelConfiguration()..source = ModelSource.api;
        config.apiEndpoint.text = 'https://example.com/v1';
        config.model.text = 'fixture';
        config.apiKey.text = 'never-persist';
        config.persona.text = '回复简短一些。';
        await PreferencesStore(directory).save(config.savedPreferences());
        config.dispose();
      });
      addTearDown(() => directory.delete(recursive: true));
      await tester.pumpWidget(
        HapticsApp(waveformDirectory: () async => directory),
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
          if (find.textContaining('API 模型 ·').evaluate().isNotEmpty) break;
        }
      });
      await reveal(tester, find.text('模型与对话设置'));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('model_api_key')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('model_persona')))
            .controller!
            .text,
        '回复简短一些。',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('model_name')))
            .controller!
            .text,
        'fixture',
      );
      expect(
        CoreBridge().call({'op': 'snapshot'})['state']['phase'],
        'disconnected',
      );
      await tester.ensureVisible(
        find.byKey(const Key('save_model_preferences')),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
