import 'package:haptics_lab/app_access.dart';

// Real microphone + local mock HTTP only. No provider key, cloud or audio files.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_transcription.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real microphone reaches local transcription and local chat through UI',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var audioBytes = 0, sttCalls = 0, chatCalls = 0;
      server.listen((req) async {
        final bytes = await req.fold<List<int>>(
          [],
          (all, part) => all..addAll(part),
        );
        expectSync(
          req.headers.value('authorization'),
          'Bearer fixture-local-only',
        );
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path == '/audio/transcriptions') {
          sttCalls++;
          audioBytes = bytes.length;
          expectSync(latin1.decode(bytes), contains('stt-xai-v1'));
          expectSync(latin1.decode(bytes), contains('RIFF'));
          req.response.write(jsonEncode({'text': '你好，请简短介绍自己。'}));
        } else {
          chatCalls++;
          final body = jsonDecode(utf8.decode(bytes));
          expectSync(body['model'], veniceTextModel);
          expectSync(body['messages'].last['content'], '你好，请简短介绍自己。');
          expectSync(body.containsKey('tools'), false);
          req.response.write(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {'content': '你好，我是文字聊天测试助手。'},
                },
              ],
            }),
          );
        }
        await req.response.close();
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: VeniceChatPage(
              role: AppRole.administrator,
              enableDialogueGuidance: false,
              loadKey: () async => 'fixture-local-only',
              transcriberFactory: (_) => VeniceTranscriber(
                apiKey: 'fixture-local-only',
                endpoint: Uri.parse(
                  'http://127.0.0.1:${server.port}/audio/transcriptions',
                ),
              ),
              chatFactory: (_, model) => ApiModelProvider(
                apiKey: 'fixture-local-only',
                endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1'),
                model: model,
                mode: ApiReplyMode.chat,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('venice_funded')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('venice_record')));
        await tester.tap(find.byKey(const Key('venice_record')));
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          final text = tester
              .widget<Text>(find.byKey(const Key('venice_recording_status')))
              .data!;
          if (text.contains('正在录音')) break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        await tester.pump();
        expectSync(sttCalls, 0);
        await tester.ensureVisible(find.byKey(const Key('venice_transcribe')));
        await tester.tap(find.byKey(const Key('venice_transcribe')));
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (chatCalls == 1 &&
              find.text('AI：你好，我是文字聊天测试助手。').evaluate().isNotEmpty) {
            break;
          }
        }
        expectSync(sttCalls, 1);
        expectSync(chatCalls, 1);
        expectSync(audioBytes, greaterThan(3200));
        expectSync(find.text('AI：你好，我是文字聊天测试助手。'), findsOneWidget);
        expectSync(find.text('麦克风关闭'), findsOneWidget);
        expectSync(tester.takeException(), isNull);
        final dir = Platform.environment['HAPTICS_REPORT_DIR'];
        if (dir != null) {
          await File('$dir/venice-speech-native.json').writeAsString(
            jsonEncode({
              'ok': true,
              'real_microphone': true,
              'stt_calls': sttCalls,
              'chat_calls': chatCalls,
              'multipart_bytes': audioBytes,
              'upstream_calls': 0,
              'audio_saved': false,
              'provider_auth_verified': false,
              'chinese_accuracy_verified': false,
            }),
          );
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await server.close(force: true);
      }
    },
  );
}
