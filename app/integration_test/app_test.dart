import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/main.dart';
import 'package:haptics_lab/preferences_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets('Android native UI and Rust authorization-stop flow', (
    tester,
  ) async {
    final core = CoreBridge();
    core.call({'op': 'reset_simulation'});
    await tester.pumpWidget(const HapticsApp());
    await tester.pump(const Duration(milliseconds: 400));
    expect(core.call({'op': 'snapshot'})['state']['simulation_only'], true);
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('android-home');

    await tester.tap(find.text('设备'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const Key('device_sim_single')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('authorize')));
    await tester.pump(const Duration(milliseconds: 200));
    for (var attempt = 0; attempt < 50; attempt++) {
      if (tester
              .widget<FilledButton>(find.byKey(const Key('authorize')))
              .onPressed !=
          null) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('authorize'))).onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('authorize')));
    await tester.pump();
    expect(core.call({'op': 'snapshot'})['state']['phase'], 'authorized');
    await binding.takeScreenshot('android-authorized');
    await tester.tap(find.text('体验'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.ensureVisible(find.byKey(const Key('soft_pulse')));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const Key('soft_pulse')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(core.call({'op': 'snapshot'})['state']['phase'], 'playing');
    expect(find.byKey(const Key('stop')).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump(const Duration(milliseconds: 200));
    final stopped = core.call({'op': 'snapshot'})['state'];
    expect(stopped['phase'], 'stopped');
    expect(stopped['output'], [0.0, 0.0]);
    await binding.takeScreenshot('android-stopped');
    await tester.tap(find.text('波形'));
    await tester.pump(const Duration(milliseconds: 150));
    core.call({'op': 'remove_waveform', 'waveform_id': 'gentle_import'});
    final directory = await getApplicationSupportDirectory();
    final stored = File('${directory.path}/waveforms-v1/gentle_import.json');
    if (await stored.exists()) await stored.delete();
    await tester.tap(find.byKey(const Key('import_waveform')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通用示例'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('validate_waveform')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('android-wave-preview');
    await tester.tap(find.byKey(const Key('save_waveform')));
    await tester.pumpAndSettle();
    expect(await stored.exists(), true);
    expect(
      (core.call({'op': 'snapshot'})['state']['waveforms'] as List).any(
        (w) => w['id'] == 'gentle_import',
      ),
      true,
    );
    await binding.takeScreenshot('android-wave-library');
    await tester.tap(find.text('设备'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('authorize')));
    await tester.tap(find.byKey(const Key('authorize')));
    await tester.pump();
    await tester.tap(find.text('波形'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wave_play_gentle_import')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(core.call({'op': 'snapshot'})['state']['phase'], 'playing');
    final pending = core.call({'op': 'begin_ai'})['result']['ticket'];
    expect(core.call({'op': 'set_gain', 'gain': 0.6})['ok'], true);
    final stale = core.call({
      'op': 'complete_ai',
      'ticket': pending,
      'response': jsonEncode({'action': 'set_gain', 'gain': 0.65}),
    });
    expect(stale['ok'], false);
    expect(stale['state']['gain_target'], 0.6);
    expect(stale['state']['phase'], 'playing');
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump();
    expect(core.call({'op': 'snapshot'})['state']['output'], [0.0, 0.0]);
    await tester.tap(find.text('体验'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.ensureVisible(find.byKey(const Key('start_experience')));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const Key('start_experience')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(core.call({'op': 'snapshot'})['state']['continuous'], true);
    final stronger = find.widgetWithText(ActionChip, '强一点');
    await tester.ensureVisible(stronger);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(stronger);
    await tester.pump(const Duration(milliseconds: 900));
    expect(
      core.call({'op': 'snapshot'})['state']['gain_target'],
      closeTo(0.6, 1e-8),
    );
    expect(find.textContaining('50% → 60%'), findsNWidgets(2));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('android-chat-actions');
    await tester.pump(const Duration(milliseconds: 2700));
    expect(core.call({'op': 'snapshot'})['state']['phase'], 'playing');
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump();
    expect(core.call({'op': 'snapshot'})['state']['output'], [0.0, 0.0]);
    await tester.ensureVisible(find.text('模型与对话设置'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('模型与对话设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('model_source')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('model_source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通用 API（Chat Completions）').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('model_api_key')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('model_api_key')).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('model_api_key')))
          .obscureText,
      true,
    );
    await binding.takeScreenshot('android-model-settings');
    await tester.ensureVisible(find.byKey(const Key('model_name')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('model_name')),
      'integration-fixture',
    );
    await tester.ensureVisible(find.byKey(const Key('model_api_key')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('model_api_key')),
      'fixture-not-a-real-key',
    );
    await tester.ensureVisible(find.byKey(const Key('model_persona')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('model_persona')),
      '称呼我小舟，回复简短。',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save_model_preferences')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save_model_preferences')));
    for (var attempt = 0; attempt < 50; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('配置与偏好已保存；').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('配置与偏好已保存；'), findsOneWidget);
    final preferences = PreferencesStore(
      await getApplicationSupportDirectory(),
    );
    expect(
      await preferences.file.readAsString(),
      isNot(contains('fixture-not-a-real-key')),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const HapticsApp());
    for (var attempt = 0; attempt < 50; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('API 模型 ·').evaluate().isNotEmpty) break;
    }
    await tester.ensureVisible(find.text('模型与对话设置'));
    await tester.pump();
    await tester.tap(find.text('模型与对话设置'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('model_api_key')))
          .controller!
          .text,
      isEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('model_name')))
          .controller!
          .text,
      'integration-fixture',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('model_persona')))
          .controller!
          .text,
      '称呼我小舟，回复简短。',
    );
    expect(core.call({'op': 'snapshot'})['state']['remaining_ms'], 0);
    await tester.ensureVisible(find.byKey(const Key('save_model_preferences')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('android-preferences-restored');
    await preferences.forget();
    expect(tester.takeException(), isNull);
    binding.reportData = {
      ...?binding.reportData,
      'verified': {
        'platform': 'Android API 35 x86_64 emulator',
        'native_ffi': true,
        'simulation_only': true,
        'connected_authorized_played_stopped': true,
        'import_preview_persist_play_stop': true,
        'manual_gain_revokes_pending_ai': true,
        'continuous_chat_strength_and_stop': true,
        'api_configuration_ui': true,
        'preferences_saved_and_restored_without_key_or_grant': true,
        'final_output': stopped['output'],
      },
    };
    await tester.pumpWidget(const SizedBox());
  });
}
