import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/model_settings.dart';
import 'package:haptics_lab/preferences_store.dart';

void main() {
  test('save replaces preferences, restores independently and never persists the key', () async {
    final directory = await Directory.systemTemp.createTemp('haptics-prefs-');
    addTearDown(() => directory.delete(recursive: true));
    final config = ModelConfiguration()..source = ModelSource.api;
    addTearDown(config.dispose);
    config.apiEndpoint.text = 'https://example.com/v1';
    config.model.text = 'fixture-model';
    config.apiKey.text = 'fixture-secret-never-store';
    config.persona.text = '称呼我小舟，回复简短一些。';
    config.style = '简洁';
    final store = PreferencesStore(directory);
    await store.save(config.savedPreferences());
    config.persona.text = '称呼我小舟，多问我的感受。';
    config.timeoutSeconds = 60;
    config.maxTokens = 2400;
    await store.save(config.savedPreferences());
    final source = await store.file.readAsString();
    expect(source, isNot(contains('fixture-secret')));
    expect(source, isNot(contains('apiKey')));
    final restored = ModelConfiguration();
    addTearDown(restored.dispose);
    restored.restorePreferences((await PreferencesStore(directory).load())!);
    expect(restored.apiKey.text, isEmpty);
    expect(restored.persona.text, config.persona.text);
    expect(restored.style, '简洁');
    expect(restored.timeoutSeconds, 60);
    expect(restored.maxTokens, 2400);
    expect(restored.model.text, 'fixture-model');
    await store.forget();
    expect(await store.load(), isNull);
    expect(await directory.list().toList(), isEmpty);
  });

  test('malformed, oversized and unexpected secret/session fields are not restored', () async {
    final directory = await Directory.systemTemp.createTemp('haptics-prefs-');
    addTearDown(() => directory.delete(recursive: true));
    final config = ModelConfiguration();
    addTearDown(config.dispose);
    final baseline = config.savedPreferences();
    final store = PreferencesStore(directory);
    for (final bad in [
      {...baseline, 'apiKey': 'accidental-secret'},
      {...baseline, 'authorized': true},
      {...baseline, 'source': 'automatic'},
      {...baseline, 'timeoutSeconds': 999},
      {...baseline, 'apiEndpoint': 'https://example.com?key=secret'},
      {...baseline, 'localEndpoint': 'http://remote.example/v1'},
      {...baseline, 'persona': 'x' * 1001},
    ]) {
      await store.file.writeAsString(jsonEncode(bad));
      await expectLater(store.load(), throwsFormatException);
      expect(() => config.restorePreferences(bad), throwsFormatException);
      expect(config.savedPreferences(), baseline);
    }
    for (final bad in ['{broken', ' ' * 16385]) {
      await store.file.writeAsString(bad);
      await expectLater(store.load(), throwsFormatException);
      expect(await store.file.readAsString(), bad);
    }
  });
}
