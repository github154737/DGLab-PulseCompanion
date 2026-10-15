// Local-only microphone check. Never stores samples or contacts the service.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:haptics_lab/voice_audio.dart';
import 'package:record/record.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native microphone supplies PCM and can restart', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('本地麦克风诊断：不上传、不保存录音'))),
      ),
    );
    final result = <String, dynamic>{
      'uploaded': false,
      'recording_saved': false,
    };
    final audio = NativeVoiceAudio();
    StreamSubscription<Uint8List>? subscription;
    try {
      final enumerator = AudioRecorder();
      result['permission'] = await enumerator.hasPermission();
      result['input_device_count'] =
          (await enumerator.listInputDevices()).length;
      await enumerator.dispose();
      final rounds = <Map<String, int>>[];
      for (var i = 0; i < 2; i++) {
        var chunks = 0, bytes = 0;
        final stream = await audio.capture().timeout(
          const Duration(seconds: 10),
        );
        subscription = stream.listen((chunk) {
          chunks++;
          bytes += chunk.length;
        });
        await Future<void>.delayed(const Duration(seconds: 2));
        await subscription.cancel();
        subscription = null;
        await audio.stopCapture();
        rounds.add({'chunks': chunks, 'bytes': bytes});
      }
      result['rounds'] = rounds;
      result['ok'] = rounds.every((r) => r['bytes']! > 0);
    } catch (error) {
      result['ok'] = false;
      result['error_type'] = '${error.runtimeType}';
      if (error is PlatformException) {
        result['code'] = error.code;
        result['message'] = error.message;
        result['details'] = '${error.details}';
      }
    } finally {
      await subscription?.cancel();
      try {
        await audio.dispose();
      } catch (_) {
        result['cleanup_error'] = true;
      }
      final path = const String.fromEnvironment('MIC_REPORT');
      if (path.isNotEmpty) await File(path).writeAsString(jsonEncode(result));
      debugPrint('MIC_DIAGNOSTIC ${jsonEncode(result)}');
    }
    expect(result['ok'], true);
  });
}
