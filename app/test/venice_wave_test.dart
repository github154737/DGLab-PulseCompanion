import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/pulse_library.dart';
import 'package:haptics_lab/venice_wave_session.dart';

void main() {
  const sample = 'Dungeonlab+pulse:8,1,8=0,20,0,1,1/0.00-1,50.00-0,100.00-1';
  test('native pulse import retains every original byte for export', () {
    final bytes = utf8.encode('$sample\r\n');
    final wave = PulseWave.parse('测试.pulse', bytes);
    expect(wave.bytes, bytes);
    expect(wave.levels, [0, .5, 1]);
    expect(wave.deviceReady, false);
    expect(
      () => PulseWave.parse(
        'x.pulse',
        utf8.encode(sample.replaceFirst('100.00', '101.00')),
      ),
      throwsFormatException,
    );
  });
  test(
    'archive imports without extracting paths and deduplicates exact bytes',
    () {
      final bytes = utf8.encode(sample);
      final zip = Archive()
        ..addFile(ArchiveFile('../../first.pulse', bytes.length, bytes))
        ..addFile(ArchiveFile('second.pulse', bytes.length, bytes));
      final result = importPulseFiles('x.zip', ZipEncoder().encode(zip));
      expect(result.waves.length, 1);
      expect(result.duplicates, 1);
      expect(result.waves.first.name, 'first');
    },
  );
  test('private archive parses and exported bytes match source entries', () {
    final bytes = File('assets/user-waveforms.zip').readAsBytesSync();
    final result = importPulseFiles('user.zip', bytes);
    expect(result.waves.length, greaterThan(200));
    final source = <String>{};
    void collect(List<int> data) {
      for (final e in ZipDecoder().decodeBytes(data)) {
        if (!e.isFile || !e.name.endsWith('.pulse')) continue;
        final content = e.content;
        if (content.length >= 4 && content[0] == 80 && content[1] == 75) {
          collect(content);
        } else {
          source.add(base64Encode(content));
        }
      }
    }

    collect(bytes);
    expect(result.waves.length, 343);
    expect(result.duplicates, 97);
    expect(result.errors, ['混乱涡旋.pulse']);
    for (final w in result.waves) {
      expect(source.contains(base64Encode(w.bytes)), true);
    }
  }, skip: !const bool.fromEnvironment('PILOT_ASSET_TEST'));
  test('limits, stale requests and imported physical output are enforced', () {
    var clock = DateTime(2026, 10, 10);
    final session = VeniceWaveSession(now: () => clock);
    addTearDown(session.dispose);
    Map<String, dynamic> action(int a) => {
      'action': 'set',
      'a': a,
      'b': 0,
      'waveform_id': session.selected,
    };
    session.apply(action(2), session.epoch);
    expect(session.strength, [0, 0]);
    session.grant();
    session.apply(action(6), session.epoch);
    expect(session.strength, [0, 0]);
    session.apply(action(2), session.epoch);
    expect(session.strength, [2, 0]);
    final old = session.epoch;
    session.stop();
    session.grant();
    session.apply(action(4), old);
    expect(session.strength, [0, 0]);
    final imported = importPulseFiles('x.pulse', utf8.encode(sample));
    session.add(imported);
    session.candidates.add(imported.waves.first.id);
    session.apply({
      ...action(2),
      'waveform_id': imported.waves.first.id,
    }, session.epoch);
    expect(session.selected, imported.waves.first.id);
    session.grant(toDevice: true);
    session.apply({
      ...action(2),
      'waveform_id': imported.waves.first.id,
    }, session.epoch);
    expect(session.wave.deviceReady, true);
    expect(session.strength, [0, 0]);
    clock = clock.add(const Duration(seconds: 121));
    session.tick();
    expect(session.active, true);
    expect(session.physicalState()['phase'], 'playing');
    expect(session.snapshot()['remaining_ms'], isNull);
    session.stop();
    expect(session.physicalState()['phase'], 'stopped');
  });
  test('simulation remains active beyond 120 seconds and cannot emit physical output', () {
    var clock = DateTime(2026, 10, 10);
    final session = VeniceWaveSession(now: () => clock);
    session.grant();
    clock = clock.add(const Duration(days: 2));
    session.tick();
    expect(session.active, true);
    expect(session.deadline, isNull);
    expect(session.snapshot()['remaining_ms'], isNull);
    expect(session.physicalState()['phase'], 'stopped');
    session.stop();
    expect(session.active, false);
    session.grant(toDevice: true);
    clock = clock.add(const Duration(seconds: 121));
    session.tick();
    expect(session.active, true);
    session.stop();
    expect(session.active, false);
    session.dispose();
  });
  test('pain and explicit stop do not depend on cloud inference', () {
    for (final text in ['有点疼', '停止', '不舒服', 'stop']) {
      expect(VeniceWaveSession.needsStop(text), true);
    }
    expect(VeniceWaveSession.needsStop('A 通道强一点'), false);
  });
}
