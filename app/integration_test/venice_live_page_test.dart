import 'package:haptics_lab/app_access.dart';

// Opt-in paid integration test. Uses synthetic speech, never the microphone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_recorder.dart';

class FixtureCapture implements SpeechCapture {
  FixtureCapture(this.pcm);
  final Uint8List pcm;
  StreamController<Uint8List>? stream;
  @override
  Future<Stream<Uint8List>> start() async {
    stream = StreamController<Uint8List>();
    stream!.add(pcm);
    return stream!.stream;
  }

  @override
  Future<void> stop() async {
    await stream?.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'live key -> text send -> synthetic recording -> STT -> automatic chat',
    (tester) async {
      final root = Platform.environment['HAPTICS_REPORT_DIR']!;
      final pcm = await File(Platform.environment['HAPTICS_SYNTHETIC_PCM']!)
          .readAsBytes();
      await tester.pumpWidget(
        MaterialApp(
          home: VeniceChatPage(
            role: AppRole.administrator,
            recorder: VeniceRecorder(capture: FixtureCapture(pcm)),
          ),
        ),
      );
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 650; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (ready()) return;
        }
        fail('Page flow timed out; response contents omitted.');
      }

      Future<void> tap(String key) async {
        final finder = find.byKey(Key(key));
        await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pump();
      }

      await waitFor(() => find.textContaining('本机密钥已加载').evaluate().isNotEmpty);
      await tap('venice_funded');
      await tester.enterText(
        find.byKey(const Key('venice_message')),
        '请只回复：界面连接成功。',
      );
      await tap('venice_send');
      await waitFor(() => find.textContaining('收到回复').evaluate().isNotEmpty);
      await tap('venice_record');
      await waitFor(() => find.textContaining('正在录音 ·').evaluate().isNotEmpty);
      expectSync(
        tester
            .widget<FilledButton>(find.byKey(const Key('venice_transcribe')))
            .onPressed,
        isNotNull,
      );
      await tap('venice_transcribe');
      await waitFor(
        () =>
            find.byKey(const Key('venice_transcript')).evaluate().isNotEmpty &&
            find.textContaining('收到回复').evaluate().isNotEmpty,
      );
      final transcript = tester
          .widget<SelectableText>(find.byKey(const Key('venice_transcript')))
          .data!;
      expectSync(transcript.toLowerCase(), contains('hello'));
      expectSync(find.text('麦克风关闭'), findsOneWidget);
      expectSync(tester.takeException(), isNull);
      await File('$root/venice-live-page.json').writeAsString(
        jsonEncode({
          'ok': true,
          'native_key_load': true,
          'text_button_cloud_reply': true,
          'stop_transcribe_button_cloud_stt': true,
          'auto_send_cloud_reply': true,
          'speech_source': 'synthetic_fixture',
          'microphone_uploaded': false,
          'chat_requests': 2,
          'stt_requests': 1,
        }),
      );
      await tester.pumpWidget(const SizedBox());
    },
    skip: !const bool.fromEnvironment('VENICE_LIVE_TEST'),
  );
}
