import 'package:haptics_lab/app_access.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/continuous_voice.dart';
import 'package:haptics_lab/model_provider.dart';
import 'package:haptics_lab/speech_audio_player.dart';
import 'package:haptics_lab/speech_widgets.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_recorder.dart';
import 'package:haptics_lab/venice_tts.dart';
import 'package:haptics_lab/venice_wave_session.dart';

import 'warm_test_helpers.dart';

class _SpeechChat extends ModelProvider {
  int calls = 0;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) async {
    calls++;
    return const ModelReply('收到你的消息，今天过得怎么样？', {});
  }
}

class _HoldPlanner extends ModelProvider {
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) async => const ModelReply('{"action":"hold"}', {});
}

class _UiTts extends VeniceTtsClient {
  _UiTts() : super(apiKey: 'fixture');
  final inputs = <String>[];
  final voices = <String>[];
  bool fail = false;

  @override
  Future<Uint8List> synthesize(
    String text, {
    String voice = 'eve',
    double speed = 1,
  }) async {
    inputs.add(text);
    voices.add(voice);
    if (fail) {
      throw const ModelServiceException('朗读服务返回 HTTP 502，请重试。');
    }
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  void cancel() {}
}

class _UiPlayer implements SpeechAudioPlayer {
  final controller = StreamController<SpeechPlaybackEvent>.broadcast(
    sync: true,
  );
  int plays = 0, stops = 0;
  bool playing = false;

  @override
  Stream<SpeechPlaybackEvent> get events => controller.stream;

  @override
  Future<void> play(Uint8List bytes) async {
    plays++;
    playing = true;
    controller.add(
      const SpeechPlaybackEvent(
        SpeechPlaybackState.playing,
        position: Duration(seconds: 1),
        duration: Duration(seconds: 5),
      ),
    );
  }

  void complete() {
    playing = false;
    controller.add(const SpeechPlaybackEvent(SpeechPlaybackState.completed));
  }

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
  }

  @override
  Future<void> dispose() async {
    playing = false;
    await controller.close();
  }
}

class _UiCapture extends SpeechCapture {
  final controller = StreamController<Uint8List>.broadcast();
  int starts = 0;

  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    return controller.stream;
  }

  @override
  Future<void> stop() async {}
}

class _UiHarness {
  final tts = _UiTts();
  final player = _UiPlayer();
  final chat = _SpeechChat();
  final waves = VeniceWaveSession();
  final capture = _UiCapture();
  late final recorder = VeniceRecorder(capture: capture);
}

// Audio and waveform animations intentionally never settle while active.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

Future<_UiHarness> _mount(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  GlobalKey? boundaryKey,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(tester.view.resetViewInsets);
  final directory = (await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('speech-chat-ui-');
    await File('${dir.path}/warm-preferences-v1.json')
        .writeAsString(jsonEncode({'version': 2, 'funded': true}));
    return dir;
  }))!;
  final h = _UiHarness();
  addTearDown(() async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await h.capture.controller.close();
    h.waves.dispose();
    await tester.runAsync(() => directory.delete(recursive: true));
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: VeniceChatPage(
          role: AppRole.administrator,
          enableDialogueGuidance: false,
          loadKey: () async => 'fixture',
          preferencesDirectory: directory,
          waveSession: h.waves,
          recorder: h.recorder,
          chatFactory: (_, _) => h.chat,
          plannerFactory: (_, _) => _HoldPlanner(),
          ttsFactory: (_) => h.tts,
          speechPlayer: h.player,
        ),
      ),
    ),
  );
  await settleWarm(tester);
  final dynamic state = tester.state(find.byType(VeniceChatPage));
  // restore() crosses asset loading, ZIP decoding and several real filesystem
  // futures. pumpAndSettle only observes frames, not these pending I/O stages.
  for (var i = 0; i < 100 && state.library.ready != true; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  expect(
    state.library.ready,
    isTrue,
    reason: 'preferences restore not finished',
  );
  expect(
    state.library.funded,
    isTrue,
    reason:
        'fixture funded state not restored; notice=${state.library.notice}; waves=${h.waves.waves.length}',
  );
  expect(state.secret != null, isTrue, reason: 'fixture key has not loaded');
  expect(
    state.occupied,
    isFalse,
    reason:
        'page still occupied: keyLoading=${state.keyLoading}, busy=${state.busy}, recorder=${h.recorder.phase}',
  );
  // The final I/O continuation may mark the page dirty after the prior frame's
  // build phase. Render that funded-state notification before inspecting UI.
  await tester.pumpAndSettle();
  expect(
    tester.widget<IconButton>(find.byKey(const Key('venice_send'))).onPressed,
    isNotNull,
    reason: 'WarmLibrary should restore funded=true before the test sends',
  );
  return h;
}

Future<void> _send(WidgetTester tester, [String text = '你好，今天好吗？']) async {
  await tester.enterText(find.byKey(const Key('venice_message')), text);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.ensureVisible(find.byKey(const Key('venice_send')));
  await tester.tap(find.byKey(const Key('venice_send')));
  await _frames(tester);
}

void main() {
  testWidgets('reply automatically speaks with Eve and only reads reply text', (
    tester,
  ) async {
    final h = await _mount(tester);
    await _send(tester);
    expect(h.chat.calls, 1);
    expect(h.tts.inputs, ['收到你的消息，今天过得怎么样？']);
    expect(h.tts.voices, ['eve']);
    expect(h.player.plays, 1);
    expect(h.player.playing, isTrue);
    expect(find.byKey(const Key('speech_now_playing')), findsOneWidget);
    expect(find.byType(VoiceBars), findsWidgets);
    expect(find.byKey(const Key('chat_persistent_control')), findsOneWidget);
    expect(find.byTooltip('关闭自动朗读'), findsOneWidget);
    h.player.complete();
    await _frames(tester);
    expect(find.byKey(const Key('speech_now_playing')), findsNothing);
    expect(find.text('收到你的消息，今天过得怎么样？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'automatic speech can be disabled while manual reply playback works',
    (tester) async {
      final h = await _mount(tester);
      await tester.tap(find.byKey(const Key('chat_auto_speak')));
      await _frames(tester);
      await _send(tester);
      expect(h.tts.inputs, isEmpty);
      expect(h.player.plays, 0);
      expect(find.byTooltip('开启自动朗读'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('朗读'));
      await tester.tap(find.byTooltip('朗读'));
      await _frames(tester);
      expect(h.tts.voices, ['eve']);
      expect(h.player.playing, isTrue);
      expect(find.byKey(const Key('stop_speech')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('stop_speech')));
      await tester.tap(find.byKey(const Key('stop_speech')));
      await _frames(tester);
      expect(h.player.playing, isFalse);
      expect(find.byKey(const Key('speech_now_playing')), findsNothing);
    },
  );

  testWidgets(
    'starting recording interrupts speech without removing waveform controls',
    (tester) async {
      final h = await _mount(tester);
      await _send(tester);
      expect(h.player.playing, isTrue);
      final beforeStop = h.player.stops;
      await tester.tap(find.byKey(const Key('show_recording')));
      await _frames(tester);
      await tester.ensureVisible(find.byKey(const Key('venice_record')));
      await tester.tap(find.byKey(const Key('venice_record')));
      await _frames(tester);
      expect(h.capture.starts, 1);
      expect(h.recorder.capturing, isTrue);
      expect(h.player.stops, greaterThan(beforeStop));
      expect(h.player.playing, isFalse);
      expect(find.byKey(const Key('speech_now_playing')), findsNothing);
      expect(find.byKey(const Key('chat_persistent_control')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TTS failure retains chat text and the authorized simulation', (
    tester,
  ) async {
    final h = await _mount(tester);
    h.tts.fail = true;
    h.waves.grant();
    h.waves.apply({
      'action': 'set',
      'a': 2,
      'b': 4,
      'waveform_id': h.waves.selected,
    }, h.waves.epoch);
    await _send(tester);
    expect(h.tts.inputs, hasLength(1));
    expect(h.player.plays, 0);
    expect(h.waves.active, isTrue);
    expect(h.waves.strength, [2, 4]);
    expect(find.text('收到你的消息，今天过得怎么样？'), findsOneWidget);
    expect(find.byKey(const Key('speech_error')), findsOneWidget);
    expect(find.textContaining('HTTP 502'), findsOneWidget);
    expect(find.byKey(const Key('chat_persistent_control')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '320x640 at 2x text size retains input and speech controls with keyboard',
    (tester) async {
      final h = await _mount(tester, size: const Size(320, 640), textScale: 2);
      await _send(tester);
      expect(h.player.playing, isTrue);
      expect(tester.takeException(), isNull, reason: 'small screen playing');
      await tester.enterText(find.byKey(const Key('venice_message')), '下一条文字');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await _frames(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: 'playing with keyboard visible',
      );
      expect(find.byKey(const Key('chat_persistent_control')), findsOneWidget);
      expect(find.byKey(const Key('venice_message')), findsOneWidget);
      expect(find.byKey(const Key('stop_speech')), findsOneWidget);
      tester.view.resetViewInsets();
      FocusManager.instance.primaryFocus?.unfocus();
      await _frames(tester);
      expect(tester.takeException(), isNull, reason: 'keyboard hidden');
    },
  );

  testWidgets(
    'background lifecycle does not cancel speech or start another paid request',
    (tester) async {
      final h = await _mount(tester);
      h.waves.grant();
      await _send(tester);
      expect(h.player.playing, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(h.player.playing, isTrue);
      expect(h.waves.active, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _frames(tester);
      expect(h.player.playing, isTrue);
      expect(h.waves.active, isTrue);
      expect(h.tts.inputs, hasLength(1));
      expect(h.player.plays, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('render speech chat and settings for visual review', (
    tester,
  ) async {
    const output = String.fromEnvironment('SPEECH_PREVIEW_DIR');
    expect(output, isNotEmpty);
    final folder = Directory(output);
    await tester.runAsync(() async {
      await folder.create(recursive: true);
      final bytes = await File(
        '${Platform.environment['WINDIR']}/Fonts/msyh.ttc',
      ).readAsBytes();
      for (final family in ['Roboto', 'sans-serif']) {
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    final boundaryKey = GlobalKey();
    final h = await _mount(
      tester,
      size: const Size(412, 915),
      boundaryKey: boundaryKey,
    );
    Future<void> capture(String name) async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final frame = await boundary.toImage(pixelRatio: 2);
        final png = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File('${folder.path}/speech-$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
        frame.dispose();
      });
    }

    h.waves.grant();
    h.waves.apply({
      'action': 'set',
      'a': 4,
      'b': 4,
      'waveform_id': h.waves.selected,
    }, h.waves.epoch);
    await _send(tester, '今天有点累，陪我聊一会儿吧。');
    expect(h.player.playing, isTrue);
    expect(tester.takeException(), isNull);
    await capture('chat-playing');
    h.player.complete();
    final dynamic state = tester.state(find.byType(VeniceChatPage));
    state.updateView(() {
      state.turns.addAll(const [
        ChatTurn('user', '先调低一点，我们聊聊今天的事。'),
        ChatTurn('assistant', '你今天最想分享哪件事？我在听。'),
        ChatTurn('user', '今天终于把一直拖着的工作完成了。'),
        ChatTurn('assistant', '听起来可以松口气了。你接下来想怎么放松一下？'),
      ]);
      state.continuous.phase = ContinuousPhase.listening;
      state.continuous.bargeIn = true;
    });
    await _frames(tester);
    expect(
      tester.getSize(find.byKey(const Key('chat_messages'))).height,
      greaterThan(460),
    );
    await capture('continuous-compact');
    state.updateView(() => state.continuous.phase = ContinuousPhase.off);
    await tester.tap(find.byKey(const Key('nav_mine')));
    await _frames(tester);
    await tester.ensureVisible(find.byKey(const Key('speech_settings')));
    await _frames(tester);
    expect(tester.takeException(), isNull);
    await capture('settings');
  }, skip: !const bool.fromEnvironment('SPEECH_UI_PREVIEW'));
}
