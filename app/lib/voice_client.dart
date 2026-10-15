import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'beta_api.dart';
import 'realtime_probe.dart';
import 'simulation_session.dart';
import 'voice_audio.dart';

class VoiceClient extends ChangeNotifier {
  VoiceClient(this.core, {VoiceAudio? audio})
    : audio = audio ?? NativeVoiceAudio() {
    probe = RealtimeProbe(core, event);
    simulation = SimulationSession(core, (receipt) {
      executionReceipts.add({
        'at': DateTime.now().toUtc().toIso8601String(),
        ...receipt,
      });
      if (executionReceipts.length > 80) executionReceipts.removeAt(0);
      event({'type': 'receipt', ...receipt});
      if (probe.ready) {
        probe.send({
          'type': 'conversation.item.create',
          'item': {
            'type': 'message',
            'role': 'user',
            'content': [
              {
                'type': 'input_text',
                'text': '本地模拟实际执行回执：${jsonEncode(receipt)}。仅以实际回执说明结果。',
              },
            ],
          },
        });
      }
    });
    probe.autonomous = simulation;
  }
  final ProbeCore core;
  final VoiceAudio audio;
  late final RealtimeProbe probe;
  late final SimulationSession simulation;
  BetaApi? api;
  StreamSubscription<Uint8List>? _capture;
  Timer? _ticker;
  bool capturing = false,
      starting = false,
      speaker = false,
      dead = false,
      _polling = false;
  bool headphones = false;
  bool _openingMic = false;
  DateTime _echoGuard = DateTime.fromMillisecondsSinceEpoch(0);
  int generation = 0;
  String status = '使用邀请码登录，供应商密钥由项目方管理', receiptText = '';
  final List<Map<String, String>> transcripts = [];
  final List<int> playbackStartMs = [], stopMs = [];
  final List<Map<String, dynamic>> executionReceipts = [];
  DateTime? speechEnded;
  DateTime? backendPulse;
  DateTime lastPlan = DateTime.fromMillisecondsSinceEpoch(0);
  int _pendingPlayback = 0;
  VoiceAudioFailure? captureFailure;
  String pauseReason = '';
  int captureChunks = 0, captureBytes = 0, cleanupFailures = 0;
  double microphoneLevel = 0;
  void changed() {
    if (!dead) notifyListeners();
  }

  Future<void> redeem(String address, String code) async {
    final next = BetaApi(address);
    await next.redeem(code);
    api = next;
    status = '邀请码已兑换，可以连接语音';
    changed();
  }

  Future<void> connect({
    String style = 'playful',
    String roleContext = '',
  }) async {
    if (probe.ready || probe.connecting) return;
    if (api == null) throw StateError('请先登录');
    probe.roleContext = roleContext;
    await probe.startConnection(api!.connect, selectedStyle: style);
    if (dead) {
      await probe.close();
      return;
    }
    status = probe.status;
    backendPulse = DateTime.now();
    _ticker?.cancel();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => unawaited(tick()),
    );
    changed();
  }

  Future<void> tick() async {
    if (dead || _polling) return;
    _polling = true;
    try {
      if (probe.ready &&
          backendPulse != null &&
          DateTime.now().difference(backendPulse!) >
              const Duration(seconds: 3)) {
        await disconnect('service_heartbeat_timeout');
        return;
      }
      if (capturing && probe.ready) {
        simulation.tick();
      } else if (simulation.active) {
        simulation.stop();
      }
      _pendingPlayback = await audio.pending();
      speaker = _pendingPlayback > 0;
      if (speaker) {
        _echoGuard = DateTime.now().add(const Duration(milliseconds: 250));
      }
      if (simulation.active &&
          simulation.planningEnabled &&
          simulation.queued == 0 &&
          !probe.busy &&
          !speaker &&
          DateTime.now().difference(lastPlan).inSeconds >= 8) {
        lastPlan = DateTime.now();
        probe.requestPlan();
      }
      changed();
    } catch (_) {
      await disconnect('audio_error');
    } finally {
      _polling = false;
    }
  }

  Future<void> startMic() async {
    if (!probe.ready || starting || capturing || dead || _openingMic) return;
    _openingMic = true;
    final epoch = ++generation;
    starting = true;
    captureFailure = null;
    captureChunks = 0;
    captureBytes = 0;
    microphoneLevel = 0;
    status = '正在打开麦克风…';
    changed();
    try {
      final stream = await audio.capture();
      if (epoch != generation || dead || !probe.ready) {
        await audio.stopCapture();
        return;
      }
      capturing = true;
      status = '麦克风采集中 · 正在上传';
      _capture = stream.listen(
        (bytes) {
          if (epoch != generation || !capturing || !probe.ready) return;
          captureChunks++;
          captureBytes += bytes.length;
          var peak = 0;
          final pcm = ByteData.sublistView(bytes);
          for (var i = 0; i + 1 < bytes.length; i += 2) {
            final sample = pcm.getInt16(i, Endian.little).abs();
            if (sample > peak) peak = sample;
          }
          microphoneLevel = peak / 32768;
          // Speaker mode gates upload while playback is pending; explicit interrupt reopens capture.
          if (!headphones && (speaker || DateTime.now().isBefore(_echoGuard))) {
            return;
          }
          probe.appendAudio(bytes);
        },
        onError: (Object error) {
          if (epoch == generation && capturing) unawaited(captureFailed(error));
        },
        onDone: () {
          if (epoch == generation && capturing) {
            unawaited(
              captureFailed(const VoiceAudioFailure('capture_ended', 'stream')),
            );
          }
        },
      );
    } catch (error) {
      if (epoch == generation && !dead) await captureFailed(error);
    } finally {
      _openingMic = false;
      if (epoch == generation) starting = false;
      changed();
    }
  }

  Future<void> captureFailed(Object error) async {
    final failure = VoiceAudioFailure.from(error, 'capture');
    await pause(reason: 'capture_failure');
    captureFailure = failure;
    status = failure.message;
    changed();
  }

  Future<void> pause({String reason = 'user_pause'}) async {
    generation++;
    pauseReason = reason;
    starting = false;
    capturing = false;
    probe.pause();
    simulation.stop();
    final old = _capture;
    _capture = null;
    for (final cleanup in <Future<void> Function()>[
      () async {
        await old?.cancel();
      },
      audio.stopCapture,
      audio.stopPlayback,
    ]) {
      try {
        await cleanup();
      } catch (_) {
        cleanupFailures++;
      }
    }
    speaker = false;
    microphoneLevel = 0;
    status = reason.startsWith('window_')
        ? '窗口已隐藏，麦克风已暂停；返回后点击开启麦克风'
        : '麦克风已暂停 · 语音连接保留，可重新开启';
    changed();
  }

  Future<void> interrupt() async {
    probe.interrupt(clearInput: true);
    simulation.feedback();
    await audio.stopPlayback();
    speaker = false;
    changed();
  }

  void stop() {
    final watch = Stopwatch()..start();
    probe.stopOutput();
    simulation.stop();
    unawaited(audio.stopPlayback().catchError((Object _) {}));
    stopMs.add(watch.elapsedMilliseconds);
    if (stopMs.length > 100) stopMs.removeAt(0);
    speaker = false;
    receiptText = '已停止：权限、计划和旧轮次全部撤销';
    changed();
  }

  void authorize({int seconds = 60, double limit = 0.3, double ceiling = 0.7}) {
    if (!capturing || !probe.ready) return;
    probe.interrupt(clearInput: true);
    final r = simulation.grant(
      seconds: seconds,
      limit: limit,
      ceiling: ceiling,
    );
    if (r['ok'] == true) {
      lastPlan = DateTime.now();
      probe.requestPlan();
    } else {
      receiptText = '授权失败：${r['error']}';
    }
    changed();
  }

  void resumePlan() {
    if (!capturing || !probe.ready || !simulation.active) return;
    simulation.planningEnabled = true;
    lastPlan = DateTime.now();
    probe.requestPlan();
    changed();
  }

  void text(String value) {
    if (value.trim().isEmpty) return;
    if (RegExp(
      r'停止|停下|不要了|不舒服|^停$|^stop$',
      caseSensitive: false,
    ).hasMatch(value.trim())) {
      stop();
    }
    transcripts.add({'speaker': 'user', 'text': value});
    trim();
    probe.requestText(value);
    changed();
  }

  void trim() {
    while (transcripts.length > 80) {
      transcripts.removeAt(0);
    }
  }

  void event(Map<String, dynamic> e) {
    if (dead) return;
    switch (e['type']) {
      case 'service.heartbeat':
        backendPulse = DateTime.now();
      case 'speech':
        if (e['active'] == false) speechEnded = DateTime.now();
      case 'audio':
        if (!capturing) return;
        try {
          final bytes = base64Decode(e['data'] as String);
          speaker = true;
          unawaited(
            audio
                .feed(bytes)
                .then((_) {
                  if (speechEnded != null) {
                    playbackStartMs.add(
                      DateTime.now().difference(speechEnded!).inMilliseconds,
                    );
                    if (playbackStartMs.length > 100) {
                      playbackStartMs.removeAt(0);
                    }
                    speechEnded = null;
                  }
                })
                .catchError((Object _) {
                  unawaited(disconnect('playback_error'));
                }),
          );
        } catch (_) {
          unawaited(disconnect('playback_error'));
        }
      case 'interrupt':
        unawaited(audio.stopPlayback().catchError((Object _) {}));
        speaker = false;
      case 'transcript':
        final t = e['text'];
        if (t is String) {
          transcripts.add({'speaker': e['speaker'] as String, 'text': t});
          trim();
        }
      case 'receipt':
        if (e['ok'] != true) {
          receiptText = '动作未执行：权限已失效或提议超出本次范围';
        } else if (e['scheduled'] != null) {
          receiptText = '已安排 ${e['scheduled']} 步，等待本地执行';
        } else {
          final action =
              {
                'increase': '增强',
                'decrease': '减弱',
                'stop': '停止',
                'gentle_wave': '柔和起伏',
                'soft_pulse': '轻柔脉冲',
                'hold': '保持',
              }[e['action']] ??
              '动作';
          final gain = e['gain_target'];
          receiptText =
              '$action已执行${gain is num ? ' · 相对目标 ${(gain * 100).round()}%' : ''}';
        }
      case 'state':
        status = probe.status;
      case 'closed':
        simulation.stop();
        status = e['message'] as String;
        generation++;
        capturing = false;
        starting = false;
        unawaited(_capture?.cancel());
        _capture = null;
        unawaited(audio.stopCapture().catchError((Object _) {}));
        unawaited(audio.stopPlayback().catchError((Object _) {}));
        _ticker?.cancel();
        speaker = false;
    }
    changed();
  }

  Future<void> disconnect([String reason = 'user_disconnect']) async {
    await pause();
    await probe.close(reason: reason);
    _ticker?.cancel();
    changed();
  }

  Map<String, dynamic> diagnostics() => {
    ...probe.report(),
    'autonomous_execution_receipts': executionReceipts,
    'playback_enqueue_ms': playbackStartMs.take(100).toList(),
    'local_stop_dispatch_ms': stopMs,
    'capture_diagnostic': {
      'failure': captureFailure?.diagnostic,
      'pause_reason': pauseReason,
      'chunks': captureChunks,
      'bytes': captureBytes,
      'cleanup_failures': cleanupFailures,
    },
    'note': '播放入队不是实测可听时间；不保存转写或音频。',
  };
  @override
  void dispose() {
    dead = true;
    _ticker?.cancel();
    generation++;
    capturing = false;
    unawaited(_capture?.cancel());
    simulation.stop();
    unawaited(probe.close());
    unawaited(audio.dispose());
    super.dispose();
  }
}
