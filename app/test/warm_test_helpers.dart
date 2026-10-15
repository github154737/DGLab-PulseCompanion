import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> settleWarm(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> tapWarm(WidgetTester tester, String key) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await settleWarm(tester);
  final settings = [
    'venice_funded',
    'venice_auto_send',
    'venice_reload_key',
    'edit_ai_name',
    'venice_model',
  ];
  final nav = key == 'venice_wave_grant'
      ? 'nav_interaction'
      : settings.contains(key)
      ? 'nav_mine'
      : key.startsWith('nav_')
      ? key
      : 'nav_chat';
  await tester.tap(find.byKey(Key(nav)));
  await settleWarm(tester);
  if (['venice_reload_key', 'venice_model'].contains(key) &&
      find.byKey(Key(key)).evaluate().isEmpty) {
    await tester.ensureVisible(find.text('模型与服务'));
    await tester.tap(find.text('模型与服务'));
    await settleWarm(tester);
  }
  if (['venice_record', 'venice_transcribe', 'venice_discard'].contains(key) &&
      find.byKey(Key(key)).evaluate().isEmpty) {
    await tester.tap(find.byKey(const Key('show_recording')));
    await settleWarm(tester);
  }
  final finder = find.byKey(Key(key));
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await settleWarm(tester);
}
