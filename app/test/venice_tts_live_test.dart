import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_route.dart';
import 'package:haptics_lab/venice_tts.dart';
import 'package:haptics_lab/network_diagnostics.dart';

void main() {
  test(
    'configured relay produces Chinese Eve MP3',
    () async {
      expect(VeniceRoute.isRelay, isTrue);
      final clock = Stopwatch()..start();
      final audio = await VeniceTtsClient(apiKey: VeniceRoute.relayToken)
          .synthesize('你好，我是你的语音伙伴。现在可以听到我的回复了。你随时可以停止朗读，或者开始新的录音。');
      expect(audio.length, greaterThan(1000));
      expect(NetworkTrace.report, contains('朗读'));
      expect(NetworkTrace.report, contains('中继版本 0.12.0'));
      final folder = Platform.environment['TTS_REPORT_DIR'];
      if (folder != null) {
        await Directory(folder).create(recursive: true);
        await File('$folder/eve-neutral-sample.mp3').writeAsBytes(audio);
        await File('$folder/live-result.json').writeAsString(
          jsonEncode({
            'model': veniceTtsModel,
            'voice': 'eve',
            'language': 'zh',
            'format': 'mp3',
            'bytes': audio.length,
            'elapsed_ms': clock.elapsedMilliseconds,
            'route': 'local_https_relay',
            'passed': true,
          }),
        );
      }
    },
    skip: !const bool.fromEnvironment('VENICE_TTS_LIVE'),
    timeout: const Timeout(Duration(seconds: 80)),
  );
}
