import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/waveform_store.dart';
import 'package:haptics_lab/waveform_panel.dart';

void main() {
  late Directory dir;
  late CoreBridge core;
  late WaveformStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('haptics-wave-test-');
    core = CoreBridge()..call({'op': 'reset_simulation'});
    core.call({'op': 'remove_waveform', 'waveform_id': 'store_test'});
    store = WaveformStore(dir, core);
  });
  tearDown(() async {
    core.call({'op': 'stop'});
    core.call({'op': 'remove_waveform', 'waveform_id': 'store_test'});
    await dir.delete(recursive: true);
  });
  test('atomic save, restore and delete preserve the library without authorization', () async {
    final wave = jsonDecode(envelopeExample) as Map<String, dynamic>;
    wave['id'] = 'store_test';
    await store.save(wave);
    await expectLater(store.save(wave), throwsA(isA<FileSystemException>()));
    expect(await store.restore(), isEmpty);
    final state = core.call({'op': 'snapshot'})['state'];
    expect(state['waveforms'].any((w) => w['id'] == 'store_test'), true);
    expect(state['phase'], 'disconnected');
    expect(state['output'], [0.0, 0.0]);
    expect(await store.restore(), isEmpty);
    await store.remove('store_test');
    expect(await File('${dir.path}/store_test.json').exists(), false);
  });
  test(
    'invalid files are retained, pending files ignored, traversal rejected',
    () async {
      final invalid = File('${dir.path}/broken.json');
      await invalid.writeAsString('{');
      await File('${dir.path}/unfinished.json.pending').writeAsString('{');
      expect((await store.restore()).length, 1);
      expect(await invalid.exists(), true);
      await expectLater(store.save({'id': '../escape'}), throwsFormatException);
      await expectLater(store.remove('../escape'), throwsFormatException);
    },
  );
  test(
    'mismatched stored identity is rejected before importing a ghost waveform',
    () async {
      final wave = jsonDecode(envelopeExample) as Map<String, dynamic>;
      wave['id'] = 'store_test';
      final file = File('${dir.path}/different_name.json');
      await file.writeAsString(jsonEncode(wave));
      expect((await store.restore()).length, 1);
      expect(
        core
            .call({'op': 'snapshot'})['state']['waveforms']
            .any((w) => w['id'] == 'store_test'),
        false,
      );
      expect(await file.exists(), true);
    },
  );
}
