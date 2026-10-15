// Real UI + native microphone + local socket sink. No audio leaves this PC.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:haptics_lab/beta_api.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/voice_client.dart';
import 'package:haptics_lab/voice_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('microphone button keeps capture running and supports retry', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    WebSocket? peer;
    var receivedChunks = 0;
    server.listen((request) async {
      peer = await WebSocketTransformer.upgrade(request);
      peer!.listen((raw) {
        final event = jsonDecode(raw as String);
        if (event['type'] == 'session.update') {
          peer!.add(jsonEncode({'type': 'session.updated'}));
        }
        if (event['type'] == 'input_audio_buffer.append') receivedChunks++;
      });
    });
    final voice = VoiceClient(CoreBridge().call);
    final address = 'http://127.0.0.1:${server.port}';
    voice.api = BetaApi(address)..token = 'native-test-local-only';
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          home: VoicePage(client: voice, serviceAddress: address),
        ),
      ),
    );
    try {
      await tester.tap(find.text('连接 / 重新连接'));
      for (var i = 0; i < 40 && !voice.probe.ready; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(voice.probe.ready, true);
      await tester.pump();
      for (var round = 0; round < 2; round++) {
        final before = receivedChunks;
        await tester.ensureVisible(find.text('开启麦克风并上传'));
        await tester.tap(find.text('开启麦克风并上传'));
        for (var i = 0; i < 20; i++) {
          voice.backendPulse =
              DateTime.now(); // fake sink has no periodic heartbeat
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(voice.capturing, true);
        expect(voice.captureFailure, isNull);
        expect(receivedChunks, greaterThan(before));
        expect(find.text('暂停麦克风'), findsOneWidget);
        if (round == 0) {
          final path = const String.fromEnvironment('MIC_UI_SCREENSHOT');
          if (path.isNotEmpty) {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(path).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          }
        }
        await tester.tap(find.text('暂停麦克风'));
        await tester.pumpAndSettle();
        expect(voice.capturing, false);
      }
      debugPrint('MIC_UI_LOCAL_CHUNKS $receivedChunks');
      expect(tester.takeException(), isNull);
    } finally {
      await voice.disconnect();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await peer?.close();
      await server.close(force: true);
    }
  });
}
