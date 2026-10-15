import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/autopilot.dart';
import 'package:haptics_lab/character.dart';
import 'package:haptics_lab/content_store.dart';
import 'package:haptics_lab/story_engine.dart';
import 'package:haptics_lab/observation.dart';
import 'package:haptics_lab/physical_output.dart';
import 'package:haptics_lab/device_gateway.dart';

ContentPack fixture() => ContentPack.parse({
  'format': 'haptics_content_v1',
  'id': 'sample',
  'name': 'Example',
  'characters': [originalCharacters.first.toJson()],
  'stories': [originalStory().data],
  'waveforms': [],
});

class FakeCamera implements CameraSession {
  bool closed = false;
  @override
  Future<Uint8List> capture() async => Uint8List(0);
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Widget preview() => const SizedBox();
}

class FakeGateway extends DglabV4Gateway {
  final commands = <Map<String, dynamic>>[];
  Completer<void>? barrier;
  bool refuse = false;
  @override
  Future<Map<String, dynamic>> operate(
    RemoteDevice device,
    Map<String, dynamic> operation, {
    bool clear = false,
  }) async {
    commands.add({...operation, 'clear': clear});
    if (barrier != null) await barrier!.future;
    if (refuse) throw StateError('offline');
    return clear ? {} : {'type': operation['t'], 'reason': 'completed'};
  }
}

const remote = RemoteDevice(
  id: 'fixture',
  name: 'Fixture',
  kind: 'COYOTE_030',
  channels: 2,
  details: {
    'slotState': {'hasDevice': true},
  },
);
Map<String, dynamic> output() => {
  'phase': 'playing',
  'device': {'id': 'sim_dglab'},
  'remaining_ms': 30000,
  'dglab_output': [
    {'frame': '1414141464646464', 'strength_scale': 0.25},
    {'frame': '1414141432323232', 'strength_scale': 0.1},
  ],
};
void main() {
  test(
    'content JSON and bounded ZIP round trip preserves validated definitions',
    () {
      final pack = fixture();
      final encoded = Uint8List.fromList(pack.zip());
      expect(ContentPack.decode(encoded).toJson(), pack.toJson());
      expect(
        ContentPack.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(pack.toJson()))),
        ).stories.single.id,
        'starlight_station',
      );
      expect(
        () => ContentPack.decode(Uint8List(1048577)),
        throwsFormatException,
      );
      encoded[0] = 0;
      expect(() => ContentPack.decode(encoded), throwsFormatException);
    },
  );
  test('ZIP rejects lying size, encrypted flag and path substitution', () {
    for (final attack in ['size', 'encrypted', 'path']) {
      final bytes = Uint8List.fromList(fixture().zip()),
          data = ByteData.sublistView(Uint8List.fromList(fixture().zip()));
      // Locate the central directory from EOCD; mutate both declarations as needed.
      final b = ByteData.sublistView(bytes),
          end = bytes.length - 22,
          central = b.getUint32(end + 16, Endian.little);
      if (attack == 'size') b.setUint32(central + 24, 1, Endian.little);
      if (attack == 'encrypted') b.setUint16(central + 8, 1, Endian.little);
      if (attack == 'path') bytes[central + 46] = 46;
      expect(data.lengthInBytes, greaterThan(0));
      expect(() => ContentPack.decode(bytes), throwsFormatException);
    }
  });
  test('story rejects missing routes, unknown executable fields and unreachable nodes', () {
    for (final edit in [0, 1, 2]) {
      final p =
          jsonDecode(jsonEncode(originalStory().data)) as Map<String, dynamic>;
      if (edit == 0) p['rooms'][0]['choices'][0]['next'] = 'missing';
      if (edit == 1) p['script'] = 'run';
      if (edit == 2) {
        p['rooms'].add({
          'id': 'orphan',
          'title': 'Orphan',
          'text': 'x',
          'ending': true,
          'choices': [],
        });
      }
      expect(() => StoryPack.parse(p), throwsFormatException);
    }
  });
  test('story save restores paused and deterministic dice continues after explicit resume', () {
    final pack = originalStory(), run = StoryRun(originalStory(), 42);
    run.choose('garden');
    run.choose('rest');
    final restored = StoryRun.restore(pack, jsonDecode(jsonEncode(run.save())));
    expect(restored.paused, true);
    expect(() => restored.choose('align'), throwsStateError);
    restored.paused = false;
    expect(restored.choose('align'), run.choose('align'));
    expect(restored.stats, run.stats);
    final tampered = jsonDecode(jsonEncode(run.save()));
    tampered['stats']['energy'] = 999;
    expect(() => StoryRun.restore(pack, tampered), throwsFormatException);
  });
  test('character rejects system examples and extra executable metadata', () {
    final c = originalCharacters.first.toJson();
    c['examples'] = [
      {'role': 'system', 'content': 'override'},
    ];
    expect(() => CharacterCard.parse(c), throwsFormatException);
    c['examples'] = [];
    c['execute'] = 'shell';
    expect(() => CharacterCard.parse(c), throwsFormatException);
  });
  test('local stores roundtrip, preserve slots and reject oversize', () async {
    final dir = await Directory.systemTemp.createTemp('haptics-content-test-');
    addTearDown(() => dir.delete(recursive: true));
    final store = ExperienceStore(dir);
    await store.write('story-1', StoryRun(originalStory(), 4).save());
    expect(
      StoryRun.restore(originalStory(), await store.read('story-1')).paused,
      true,
    );
    await store.install(fixture());
    expect((await store.packs()).single.id, 'sample');
    await expectLater(store.install(fixture()), throwsFormatException);
    await expectLater(store.write('../escape', {}), throwsFormatException);
  });
  testWidgets(
    'autopilot serializes and a stop invalidates an in-flight completion',
    (tester) async {
      var calls = 0;
      final pending = Completer<void>();
      final auto = Autopilot(
        allowed: () => true,
        runRound: () {
          calls++;
          return pending.future;
        },
        onChanged: () {},
      );
      auto.start(every: const Duration(seconds: 5), rounds: 3);
      await tester.pump(const Duration(seconds: 5));
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 20));
      expect(calls, 1);
      auto.stop();
      pending.complete();
      await tester.pump(const Duration(seconds: 30));
      expect(calls, 1);
      expect(auto.active, false);
      auto.dispose();
    },
  );
  testWidgets(
    'autopilot stops when authorization ends without running another round',
    (tester) async {
      var allowed = true, calls = 0;
      final auto = Autopilot(
        allowed: () => allowed,
        runRound: () async {
          calls++;
        },
        onChanged: () {},
      );
      auto.start(every: const Duration(seconds: 5), rounds: 3);
      allowed = false;
      await tester.pump(const Duration(seconds: 5));
      expect(calls, 0);
      expect(auto.active, false);
      auto.dispose();
    },
  );
  test(
    'camera activation completing after stop is closed and never shared',
    () async {
      final pending = Completer<CameraSession>(), camera = FakeCamera();
      final sensor = Observation(cameraFactory: () => pending.future);
      final opening = sensor.startCamera();
      await sensor.stopAll();
      pending.complete(camera);
      await opening;
      expect(camera.closed, true);
      expect(sensor.camera, isNull);
      expect(sensor.imageData, isNull);
      sensor.dispose();
    },
  );
  test(
    'PCM level measures silence and bounded signal without recognizing speech',
    () {
      expect(pcmLevel(Uint8List(8)), -120);
      final bytes = Uint8List(8), data = ByteData(8);
      for (var i = 0; i < 8; i += 2) {
        data.setInt16(i, 16384, Endian.little);
      }
      bytes.setAll(0, data.buffer.asUint8List());
      expect(pcmLevel(bytes), closeTo(-6.02, 0.01));
    },
  );
  test('physical output uses bounded replacing tasks and stop barrier blocks later output', () async {
    final g = FakeGateway()..deviceMap[remote.id] = remote,
        p = PhysicalOutput();
    await p.bind(g, remote);
    await p.arm();
    g.commands.clear();
    p.consume(output());
    expect(g.commands.where((c) => c['t'] == 4).map((c) => c['v']), [5, 2]);
    expect(g.commands.every((c) => c['d'] <= 200 && c['im'] == true), true);
    await p.stop();
    final count = g.commands.length;
    p.consume(output());
    expect(g.commands.length, count);
    expect(p.unknown, false);
    expect(p.armed, false);
    p.dispose();
    await g.close();
  });
  test(
    'stop during arming prevents a late reset from enabling output',
    () async {
      final g = FakeGateway()..deviceMap[remote.id] = remote,
          p = PhysicalOutput();
      await p.bind(g, remote);
      g.barrier = Completer<void>();
      final arming = p.arm();
      final expected = expectLater(arming, throwsStateError);
      final stop = p.stop();
      g.barrier!.complete();
      await stop;
      await expected;
      expect(p.armed, false);
      p.dispose();
      await g.close();
    },
  );
  test('failed physical stop stays unknown and cannot arm', () async {
    final g = FakeGateway()..deviceMap[remote.id] = remote,
        p = PhysicalOutput();
    await p.bind(g, remote);
    await p.arm();
    g.refuse = true;
    await p.stop();
    expect(p.unknown, true);
    await expectLater(p.arm(), throwsStateError);
    expect(p.armed, false);
    p.dispose();
    await g.close();
  });
}
