import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/realtime_probe.dart';
import 'package:haptics_lab/service/access_store.dart';
import 'package:haptics_lab/service/voice_service.dart';
import 'package:haptics_lab/voice_audio.dart';
import 'package:haptics_lab/voice_client.dart';
import 'package:haptics_lab/voice_page.dart';

class FakeAudio implements VoiceAudio {
  final input = StreamController<Uint8List>.broadcast();
  final played = <Uint8List>[];
  Completer<void>? opening;
  Object? captureError;
  bool failCleanup = false;
  int stopped = 0, queued = 0;
  @override
  Future<Stream<Uint8List>> capture() async {
    await opening?.future;
    if (captureError != null) throw captureError!;
    return input.stream;
  }

  @override
  Future<void> feed(Uint8List b) async {
    played.add(b);
    queued += b.length ~/ 2;
  }

  @override
  Future<int> pending() async => queued;
  @override
  Future<void> stopPlayback() async {
    queued = 0;
  }

  @override
  Future<void> stopCapture() async {
    stopped++;
    if (failCleanup) throw StateError('cleanup_failed');
  }

  @override
  Future<void> dispose() async {
    await input.close();
  }
}

class RealHttp extends HttpOverrides {}

Future<void> until(bool Function() f) async {
  for (var i = 0; i < 200; i++) {
    if (f()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('timeout');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CoreBridge core;
  setUp(() {
    core = CoreBridge();
    core.call({'op': 'reset_simulation'});
  });
  test(
    'missing recorder component survives cleanup and can be retried',
    () async {
      final audio = FakeAudio()
        ..captureError = MissingPluginException('fixture')
        ..failCleanup = true;
      final voice = VoiceClient(core.call, audio: audio);
      voice.probe.ready = true;
      await voice.startMic();
      expect(voice.capturing, false);
      expect(voice.starting, false);
      expect(voice.captureFailure?.code, 'component_missing');
      expect(voice.status, contains('音频组件未加载'));
      expect(voice.probe.ready, true);
      expect(voice.diagnostics()['capture_diagnostic']['cleanup_failures'], 1);
      voice.event({'type': 'state'});
      expect(voice.captureFailure?.code, 'component_missing');
      audio.captureError = null;
      audio.failCleanup = false;
      await voice.startMic();
      expect(voice.capturing, true);
      expect(voice.captureFailure, isNull);
      audio.input.add(Uint8List.fromList([0, 32, 0, 0]));
      await Future<void>.delayed(Duration.zero);
      expect(voice.captureChunks, 1);
      expect(voice.captureBytes, 4);
      expect(voice.microphoneLevel, 0.25);
      await voice.pause();
      expect(voice.microphoneLevel, 0);
      voice.dispose();
    },
  );
  testWidgets('microphone error is visible next to chat controls', (
    tester,
  ) async {
    final voice = VoiceClient(core.call, audio: FakeAudio());
    voice.captureFailure = const VoiceAudioFailure(
      'component_missing',
      'capture',
    );
    await tester.pumpWidget(MaterialApp(home: VoicePage(client: voice)));
    await tester.scrollUntilVisible(
      find.text(voice.captureFailure!.message),
      180,
    );
    expect(find.text(voice.captureFailure!.message), findsOneWidget);
    await tester.scrollUntilVisible(find.text('输入消息'), 180);
    expect(find.text('输入消息'), findsOneWidget);
    expect(find.text('批准 60 秒自主模拟'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets('Windows loopback screen has no invitation form', (tester) async {
    if (!Platform.isWindows) return;
    final voice = VoiceClient(core.call, audio: FakeAudio());
    await tester.pumpWidget(
      MaterialApp(
        home: VoicePage(client: voice, serviceAddress: 'http://127.0.0.1:8790'),
      ),
    );
    expect(find.text('一次性邀请码 / 账号恢复码'), findsNothing);
    expect(find.text('兑换并登录'), findsNothing);
    expect(find.text('Windows 本机测试 · 无需邀请码'), findsOneWidget);
    expect(find.text('重试连接本机服务'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets(
    'voice screen has invite login, explicit consent and reachable stop on mobile',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final voice = VoiceClient(core.call, audio: FakeAudio());
      await tester.pumpWidget(
        MaterialApp(
          home: VoicePage(
            client: voice,
            serviceAddress: 'https://beta.example.test',
          ),
        ),
      );
      expect(find.text('一次性邀请码 / 账号恢复码'), findsOneWidget);
      expect(find.text('立即停止并撤销模拟权限'), findsOneWidget);
      expect(find.text('API Key'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('立即停止并撤销模拟权限'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  test(
    'late capture permission after pause cannot send microphone data',
    () async {
      final audio = FakeAudio()..opening = Completer<void>();
      final voice = VoiceClient(core.call, audio: audio);
      voice.probe.ready = true;
      final pending = voice.startMic();
      await Future<void>.delayed(Duration.zero);
      await voice.pause();
      audio.opening!.complete();
      await pending;
      expect(voice.capturing, false);
      expect(audio.stopped, greaterThanOrEqualTo(1));
      voice.dispose();
    },
  );
  test('missing backend heartbeat stops the simulation without waiting for TCP close', () async {
    final client = VoiceClient(core.call, audio: FakeAudio());
    client.probe.ready = true;
    client.capturing = true;
    expect(client.simulation.grant(seconds: 60)['ok'], true);
    client.backendPulse = DateTime.now().subtract(const Duration(seconds: 4));
    await client.tick();
    expect(client.simulation.active, false);
    expect(client.probe.ready, false);
    expect(core.call({'op': 'snapshot'})['state']['phase'], 'stopped');
    client.dispose();
  });
  test(
    'B C D end-to-end: invitation, relay, PCM, plan, feedback, stop and reconnect',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final directory = await Directory.systemTemp.createTemp('voice-e2e-');
      final store = AccessStore(File('${directory.path}/accounts.json'));
      await store.open();
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      WebSocket? remote;
      final sent = <Map<String, dynamic>>[];
      upstream.listen((r) async {
        remote = await WebSocketTransformer.upgrade(r);
        remote!.listen((raw) {
          final e = jsonDecode(raw as String) as Map<String, dynamic>;
          sent.add(e);
          if (e['type'] == 'session.update') {
            remote!.add(jsonEncode({'type': 'session.updated'}));
          }
        });
      });
      final service = VoiceService(
        store,
        adminToken: 'fixture-admin-token-long-enough-12345',
        provider: ProbeConfig(
          'fixture.cn-beijing.maas.aliyuncs.com',
          'fixture-provider-key',
        ),
        connect: (_, _) => WebSocket.connect('ws://127.0.0.1:${upstream.port}'),
      );
      await service.start();
      final audio = FakeAudio();
      final client = VoiceClient(core.call, audio: audio);
      try {
        final code = (await store.createInvites(1)).single;
        await client.redeem(
          'http://127.0.0.1:${service.server.port}',
          code['code']!,
        );
        await client.connect();
        expect(client.probe.ready, true);
        await client.startMic();
        audio.input.add(Uint8List(320));
        await until(
          () => sent.any((e) => e['type'] == 'input_audio_buffer.append'),
        );
        client.authorize(seconds: 30, ceiling: 0.6);
        await until(() => sent.any((e) => e['type'] == 'response.create'));
        void emit(Map<String, dynamic> e) => remote!.add(jsonEncode(e));
        emit({
          'type': 'response.created',
          'response': {'id': 'r1'},
        });
        emit({
          'type': 'response.function_call_arguments.done',
          'response_id': 'r1',
          'call_id': 'p1',
          'name': 'simulation_plan',
          'arguments': jsonEncode({
            'steps': [
              {'after_ms': 0, 'action': 'gentle_wave'},
              {'after_ms': 10000, 'action': 'increase'},
            ],
          }),
        });
        emit({
          'type': 'response.done',
          'response': {
            'id': 'r1',
            'status': 'completed',
            'usage': {
              'input_tokens': 30,
              'output_tokens': 10,
              'total_tokens': 40,
            },
          },
        });
        await until(() => client.simulation.queued == 1);
        expect(core.call({'op': 'snapshot'})['state']['preset'], 'gentle_wave');
        emit({
          'type': 'response.created',
          'response': {'id': 'r2'},
        });
        emit({
          'type': 'response.audio.delta',
          'response_id': 'r2',
          'delta': base64Encode(Uint8List(480)),
        });
        await until(() => audio.played.isNotEmpty);
        emit({
          'type': 'response.done',
          'response': {
            'id': 'r2',
            'status': 'completed',
            'usage': {
              'input_tokens': 10,
              'output_tokens': 10,
              'total_tokens': 20,
            },
          },
        });
        emit({'type': 'input_audio_buffer.speech_started'});
        await until(() => client.simulation.queued == 0);
        expect(audio.queued, 0);
        client.stop();
        expect(client.simulation.active, false);
        expect(core.call({'op': 'snapshot'})['state']['phase'], 'stopped');
        await client.disconnect();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await client.connect();
        expect(client.probe.ready, true);
        expect(client.simulation.active, false);
        expect(
          jsonEncode(client.diagnostics()),
          isNot(contains('fixture-provider-key')),
        );
      } finally {
        await client.disconnect();
        client.dispose();
        await service.close();
        await remote?.close();
        await upstream.close(force: true);
        await store.close();
        await directory.delete(recursive: true);
      }
    }, RealHttp()),
  );
}
