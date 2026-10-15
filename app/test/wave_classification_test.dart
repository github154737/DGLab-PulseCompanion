import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/warm_library.dart';
import 'package:haptics_lab/venice_wave_session.dart';
import 'package:haptics_lab/pulse_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('eight defaults, readable names and searchable name tags preserve original wave', () {
    final s = VeniceWaveSession(), lib = WarmLibrary(VeniceWaveSession());
    expect(lib.categories.length, 8);
    final wave = PulseWave('pulse-变速揉捏-1234567', Uint8List.fromList([1, 2]), [
      0,
      1,
    ]);
    expect(lib.name(wave), '变速揉捏');
    expect(lib.category(wave), '变速交替');
    expect(lib.nameTags(wave), containsAll(['变速', '揉捏']));
    expect(wave.name, 'pulse-变速揉捏-1234567');
    lib.assignments[wave.id] = '我的分类';
    lib.tags[wave.id] = ['晚间'];
    expect(lib.category(wave), '我的分类');
    expect(lib.nameTags(wave), contains('晚间'));
    lib.session.dispose();
    lib.dispose();
    s.dispose();
  });
  test(
    'legacy classifications migrate without discarding manual labels',
    () async {
      final dir = await Directory.systemTemp.createTemp('wave-migration-');
      final session = VeniceWaveSession(),
          library = WarmLibrary(VeniceWaveSession(), directory: dir);
      try {
        await File('${dir.path}/warm-preferences-v1.json').writeAsString(
          jsonEncode({
            'version': 1,
            'categories': ['渐变', '脉冲', '间歇', '复合', '我的组'],
            'assignments': {session.waves.first.id: '我的组'},
            'tags': {
              session.waves.first.id: ['常用'],
            },
          }),
        );
        await library.restore();
        expect(
          library.categories,
          containsAll([...WarmLibrary.defaultCategories, '我的组']),
        );
        expect(library.category(library.session.waves.first), '我的组');
        expect(library.nameTags(library.session.waves.first), contains('常用'));
      } finally {
        library.dispose();
        library.session.dispose();
        session.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
