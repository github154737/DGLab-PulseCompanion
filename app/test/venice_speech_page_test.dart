import 'package:haptics_lab/app_access.dart';

import 'warm_test_helpers.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_recorder.dart';
import 'package:haptics_lab/venice_transcription.dart';

class Capture extends SpeechCapture {
  final stream = StreamController<Uint8List>();
  @override
  Future<Stream<Uint8List>> start() async => stream.stream;
  @override
  Future<void> stop() async {}
}

class Transcriber extends VeniceTranscriber {
  Transcriber() : super(apiKey: 'fixture');
  int calls = 0;
  bool fail = false, cancelled = false;
  Completer<String>? pending;
  @override
  Future<String> transcribe(Uint8List wav) async {
    calls++;
    expect(wav.length, 6444);
    if (fail) throw const ModelServiceException('语音服务余额不足');
    return pending?.future ?? Future.value('你好，今天怎么样？');
  }

  @override
  void cancel() {
    cancelled = true;
  }
}

class Chat extends ModelProvider {
  int calls = 0;
  bool fail = false;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) async {
    calls++;
    expect(text, '你好，今天怎么样？');
    if (fail) throw const ModelServiceException('模型服务余额不足');
    return const ModelReply('今天还不错，你呢？', {'action': 'noop'});
  }
}

Future<void> tap(WidgetTester tester, String key) => tapWarm(tester, key);

Future<void> setup(
  WidgetTester tester,
  Capture capture,
  Transcriber stt,
  Chat chat,
) async {
  await tester.binding.setSurfaceSize(const Size(1200, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: VeniceChatPage(
        role: AppRole.administrator,
        enableDialogueGuidance: false,
        recorder: VeniceRecorder(capture: capture),
        loadKey: () async => 'fixture',
        transcriberFactory: (_) => stt,
        chatFactory: (_, model) {
          expect(model, veniceTextModel);
          return chat;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tap(tester, 'venice_funded');
  expect(
    tester.widget<SwitchListTile>(find.byKey(const Key('venice_funded'))).value,
    true,
  );
  await tap(tester, 'venice_record');
  capture.stream.add(Uint8List(6400));
  await tester.pumpAndSettle();
  expect(
    tester.widget<Text>(find.byKey(const Key('venice_recording_status'))).data,
    contains('正在录音'),
  );
  expect(
    tester
        .widget<FilledButton>(find.byKey(const Key('venice_transcribe')))
        .onPressed,
    isNotNull,
  );
}

void main() {
  testWidgets(
    'failed key remains visible after cancel and retry enables text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var keyReady = false;
      final capture = Capture(), chat = Chat();
      await tester.pumpWidget(
        MaterialApp(
          home: VeniceChatPage(
            role: AppRole.administrator,
            enableDialogueGuidance: false,
            recorder: VeniceRecorder(capture: capture),
            loadKey: () async {
              if (!keyReady) throw StateError('key_missing');
              return 'fixture';
            },
            chatFactory: (_, _) => chat,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'venice_funded');
      await tap(tester, 'nav_chat');
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('venice_send')))
            .onPressed,
        isNull,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tap(tester, 'nav_mine');
      await tester.ensureVisible(find.text('模型与服务'));
      await tester.tap(find.text('模型与服务'));
      await settleWarm(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('venice_key_status'))).data,
        contains('密钥未配置'),
      );
      expect(find.byKey(const Key('venice_reload_key')), findsOneWidget);
      keyReady = true;
      await tap(tester, 'venice_reload_key');
      await tap(tester, 'nav_chat');
      await tester.enterText(
        find.byKey(const Key('venice_message')),
        '你好，今天怎么样？',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('venice_send')))
            .onPressed,
        isNotNull,
      );
      await tap(tester, 'venice_send');
      expect(chat.calls, 1);
      expect(find.text('今天还不错，你呢？'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'recording can stop without a key and transcribe after key reload',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var keyReady = false;
      final capture = Capture(), stt = Transcriber(), chat = Chat();
      final recorder = VeniceRecorder(capture: capture);
      await tester.pumpWidget(
        MaterialApp(
          home: VeniceChatPage(
            role: AppRole.administrator,
            enableDialogueGuidance: false,
            recorder: recorder,
            loadKey: () async {
              if (!keyReady) throw StateError('key_missing');
              return 'fixture';
            },
            transcriberFactory: (_) => stt,
            chatFactory: (_, _) => chat,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'venice_funded');
      await tap(tester, 'venice_record');
      capture.stream.add(Uint8List(6400));
      await tester.pumpAndSettle();
      expect(find.text('停止录音'), findsOneWidget);
      await tap(tester, 'venice_transcribe');
      expect(recorder.phase, RecordingPhase.ready);
      expect(stt.calls, 0);
      expect(chat.calls, 0);
      keyReady = true;
      await tap(tester, 'venice_reload_key');
      await tap(tester, 'venice_transcribe');
      expect(stt.calls, 1);
      expect(chat.calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('recording -> transcript -> selected model -> text reply', (
    tester,
  ) async {
    final capture = Capture(), stt = Transcriber(), chat = Chat();
    await setup(tester, capture, stt, chat);
    expect(stt.calls, 0);
    expect(chat.calls, 0);
    expect(find.byKey(const Key('chat_persistent_control')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('chat_persistent_control'))).bottom,
      lessThan(tester.getRect(find.byKey(const Key('venice_transcribe'))).top),
    );
    await tap(tester, 'venice_transcribe');
    expect(
      stt.calls,
      1,
      reason: tester.widget<Text>(find.byKey(const Key('venice_status'))).data,
    );
    expect(chat.calls, 1);
    expect(find.byKey(const Key('venice_transcript')), findsNothing);
    expect(find.byKey(const Key('chat_persistent_control')), findsOneWidget);
    expect(find.text('今天还不错，你呢？'), findsOneWidget);
    expect(find.text('麦克风关闭 · 最长 60 秒'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'STT failure never sends a chat message and allows manual retry',
    (tester) async {
      final capture = Capture(),
          stt = Transcriber()..fail = true,
          chat = Chat();
      await setup(tester, capture, stt, chat);
      await tap(tester, 'venice_transcribe');
      expect(stt.calls, 1);
      expect(chat.calls, 0);
      expect(find.text('语音服务余额不足'), findsOneWidget);
      stt.fail = false;
      await tap(tester, 'venice_transcribe');
      expect(stt.calls, 2);
      expect(chat.calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'chat failure retains transcript; retry does not upload audio again',
    (tester) async {
      final capture = Capture(),
          stt = Transcriber(),
          chat = Chat()..fail = true;
      await setup(tester, capture, stt, chat);
      await tap(tester, 'venice_transcribe');
      expect(stt.calls, 1);
      expect(chat.calls, 1);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('venice_message')))
            .controller!
            .text,
        '你好，今天怎么样？',
      );
      chat.fail = false;
      await tap(tester, 'venice_send');
      expect(stt.calls, 1);
      expect(chat.calls, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('cancelled late transcription cannot start chat', (tester) async {
    final capture = Capture(),
        stt = Transcriber()..pending = Completer<String>(),
        chat = Chat();
    await setup(tester, capture, stt, chat);
    await tap(tester, 'venice_transcribe');
    await tap(tester, 'venice_discard');
    stt.pending!.complete('你好，今天怎么样？');
    await tester.pumpAndSettle();
    expect(stt.cancelled, true);
    expect(chat.calls, 0);
    expect(find.byKey(const Key('venice_transcript')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('manual review mode stops at editable transcription', (
    tester,
  ) async {
    final capture = Capture(), stt = Transcriber(), chat = Chat();
    await tester.pumpWidget(
      MaterialApp(
        home: VeniceChatPage(
          role: AppRole.administrator,
          enableDialogueGuidance: false,
          recorder: VeniceRecorder(capture: capture),
          loadKey: () async => 'fixture',
          transcriberFactory: (_) => stt,
          chatFactory: (_, _) => chat,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tap(tester, 'venice_auto_send');
    await tap(tester, 'venice_funded');
    await tap(tester, 'venice_record');
    capture.stream.add(Uint8List(6400));
    await tester.pump();
    await tap(tester, 'venice_transcribe');
    expect(stt.calls, 1);
    expect(chat.calls, 0);
    await tap(tester, 'venice_send');
    expect(chat.calls, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
