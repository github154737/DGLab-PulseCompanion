import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/progressive_audio.dart';

void main() {
  test('localhost audio exposes bytes before producer completes', () async {
    final source = await ProgressiveAudio.open();
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await source.close();
    });
    final response = (await client.getUrl(source.uri)).close();
    source.add(Uint8List.fromList([1, 2, 3]));
    final parts = StreamIterator(await response);
    expect(await parts.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(parts.current, [1, 2, 3]);
    source.add(Uint8List.fromList([4, 5]));
    source.finish();
    final tail = <int>[];
    while (await parts.moveNext()) {
      tail.addAll(parts.current);
    }
    expect(tail, [4, 5]);
    await parts.cancel();
  });

  test(
    'tokenless and remote-style paths denied; closing releases waiters',
    () async {
      final source = await ProgressiveAudio.open();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await source.close();
      });
      final wrong = await (await client.getUrl(
        source.uri.replace(path: '/speech/wrong.mp3'),
      )).close();
      expect(wrong.statusCode, 404);
      await wrong.drain<void>();
      final address = source.uri;
      await source.close();
      await expectLater(
        client.getUrl(address).then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
    },
  );
}
