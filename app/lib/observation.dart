import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:record/record.dart';
import 'package:image/image.dart' as img;

abstract class CameraSession {
  Widget preview();
  Future<Uint8List> capture();
  Future<void> close();
}

class NativeCameraSession implements CameraSession {
  NativeCameraSession(this.controller);
  final CameraController controller;
  static Future<CameraSession> open() async {
    final devices = await availableCameras();
    if (devices.isEmpty) throw StateError('未发现摄像头');
    final camera = CameraController(
      devices.first,
      ResolutionPreset.low,
      enableAudio: false,
    );
    try {
      await camera.initialize();
      return NativeCameraSession(camera);
    } catch (_) {
      await camera.dispose();
      rethrow;
    }
  }

  @override
  Widget preview() => AspectRatio(
    aspectRatio: controller.value.aspectRatio,
    child: CameraPreview(controller),
  );
  @override
  Future<Uint8List> capture() async {
    final picture = await controller.takePicture();
    try {
      if (await picture.length() > 5 * 1024 * 1024) throw StateError('图像过大');
      return await picture.readAsBytes();
    } finally {
      final file = File(picture.path);
      if (await file.exists()) await file.delete();
    }
  }

  @override
  Future<void> close() => controller.dispose();
}

abstract class MicrophoneSession {
  Future<Stream<Uint8List>> start();
  Future<void> close();
}

class NativeMicrophoneSession implements MicrophoneSession {
  final recorder = AudioRecorder();
  @override
  Future<Stream<Uint8List>> start() async {
    if (!await recorder.hasPermission()) throw StateError('麦克风权限未开启');
    return recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
  }

  @override
  Future<void> close() async {
    try {
      await recorder.stop();
    } finally {
      await recorder.dispose();
    }
  }
}

double pcmLevel(Uint8List bytes) {
  if (bytes.length < 2) return -120;
  final data = ByteData.sublistView(bytes);
  var sum = 0.0;
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final n = data.getInt16(i, Endian.little) / 32768;
    sum += n * n;
  }
  final rms = math.sqrt(sum / (bytes.length ~/ 2));
  return rms <= 0 ? -120 : (20 * math.log(rms) / math.ln10).clamp(-120, 0);
}

class Observation extends ChangeNotifier {
  Observation({
    Future<CameraSession> Function()? cameraFactory,
    MicrophoneSession Function()? microphoneFactory,
  }) : cameraFactory = cameraFactory ?? NativeCameraSession.open,
       microphoneFactory = microphoneFactory ?? NativeMicrophoneSession.new;
  final Future<CameraSession> Function() cameraFactory;
  final MicrophoneSession Function() microphoneFactory;
  CameraSession? camera;
  MicrophoneSession? microphone;
  StreamSubscription<Uint8List>? _audio;
  Timer? _capture;
  int _cameraGeneration = 0, _micGeneration = 0;
  bool cameraStarting = false,
      micStarting = false,
      shareImage = false,
      _dead = false,
      _taking = false;
  String cameraStatus = '未开启 / Off', microphoneStatus = '未开启 / Off';
  Uint8List? thumbnail;
  double? brightness, decibels;
  DateTime? imageTime, audioTime;
  void changed() {
    if (!_dead) notifyListeners();
  }

  String get summary => [
    if (imageTime != null &&
        DateTime.now().difference(imageTime!) < const Duration(seconds: 15))
      'Camera brightness ${brightness?.toStringAsFixed(0)} / 255.',
    if (audioTime != null &&
        DateTime.now().difference(audioTime!) < const Duration(seconds: 3))
      'Microphone level ${decibels?.toStringAsFixed(0)} dBFS (not speech recognition).',
  ].join(' ');
  String? get imageData =>
      shareImage &&
          thumbnail != null &&
          camera != null &&
          imageTime != null &&
          DateTime.now().difference(imageTime!) < const Duration(seconds: 15)
      ? 'data:image/jpeg;base64,${base64Encode(thumbnail!)}'
      : null;
  Future<void> startCamera() async {
    if (camera != null || cameraStarting || _dead) return;
    final stamp = ++_cameraGeneration;
    cameraStarting = true;
    cameraStatus = '正在开启 / Opening';
    changed();
    try {
      final next = await cameraFactory();
      if (_dead || stamp != _cameraGeneration) {
        await next.close();
        return;
      }
      camera = next;
      cameraStatus = '本机预览开启 / Local preview on';
      changed();
      await capture(stamp);
      if (!_dead && stamp == _cameraGeneration && camera != null) {
        _capture = Timer.periodic(
          const Duration(seconds: 5),
          (_) => unawaited(capture(stamp)),
        );
      }
    } catch (_) {
      if (stamp == _cameraGeneration) {
        await stopCamera();
        cameraStatus = '摄像头不可用，请检查权限 / Camera unavailable';
      }
    } finally {
      if (stamp == _cameraGeneration) {
        cameraStarting = false;
        changed();
      }
    }
  }

  Future<void> capture(int stamp) async {
    if (_taking || camera == null) return;
    _taking = true;
    try {
      final bytes = await camera!.capture();
      if (_dead || stamp != _cameraGeneration) return;
      final decoded = img.decodeImage(bytes);
      if (decoded == null || decoded.width > 2048 || decoded.height > 2048) {
        throw StateError('Unsupported frame');
      }
      final small = img.copyResize(decoded, width: 320);
      double total = 0;
      var count = 0;
      for (var y = 0; y < small.height; y += 8) {
        for (var x = 0; x < small.width; x += 8) {
          final p = small.getPixel(x, y);
          total += 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b;
          count++;
        }
      }
      brightness = total / count;
      thumbnail = Uint8List.fromList(img.encodeJpg(small, quality: 65));
      imageTime = DateTime.now();
      changed();
    } catch (_) {
      if (stamp == _cameraGeneration) {
        thumbnail = null;
        imageTime = null;
        cameraStatus = '画面采集失败 / Capture failed';
        changed();
      }
    } finally {
      _taking = false;
    }
  }

  Future<void> stopCamera() async {
    _cameraGeneration++;
    _capture?.cancel();
    _capture = null;
    cameraStarting = false;
    final old = camera;
    camera = null;
    shareImage = false;
    thumbnail = null;
    imageTime = null;
    brightness = null;
    cameraStatus = '未开启 / Off';
    changed();
    try {
      await old?.close();
    } catch (_) {}
  }

  Future<void> startMic() async {
    if (microphone != null || micStarting || _dead) return;
    final stamp = ++_micGeneration;
    micStarting = true;
    microphoneStatus = '正在开启 / Opening';
    changed();
    MicrophoneSession? next;
    try {
      next = microphoneFactory();
      final stream = await next.start();
      if (_dead || stamp != _micGeneration) {
        await next.close();
        return;
      }
      microphone = next;
      microphoneStatus = '仅测量音量 / Level meter on';
      _audio = stream.listen(
        (bytes) {
          if (stamp != _micGeneration || _dead) return;
          if (audioTime != null &&
              DateTime.now().difference(audioTime!) <
                  const Duration(milliseconds: 250)) {
            return;
          }
          decibels = pcmLevel(bytes);
          audioTime = DateTime.now();
          changed();
        },
        onError: (_) {
          if (stamp == _micGeneration) {
            unawaited(stopMic());
            microphoneStatus = '麦克风采集失败 / Microphone failed';
            changed();
          }
        },
        onDone: () {
          if (stamp == _micGeneration) unawaited(stopMic());
        },
      );
    } catch (_) {
      try {
        await next?.close();
      } catch (_) {}
      if (stamp == _micGeneration) {
        microphoneStatus = '麦克风不可用，请检查权限 / Microphone unavailable';
      }
    } finally {
      if (stamp == _micGeneration) {
        micStarting = false;
        changed();
      }
    }
  }

  Future<void> stopMic() async {
    _micGeneration++;
    micStarting = false;
    final old = microphone;
    microphone = null;
    final sub = _audio;
    _audio = null;
    decibels = null;
    audioTime = null;
    microphoneStatus = '未开启 / Off';
    changed();
    await sub?.cancel();
    try {
      await old?.close();
    } catch (_) {}
  }

  Future<void> stopAll() async {
    await Future.wait([stopCamera(), stopMic()]);
  }

  @override
  void dispose() {
    _dead = true;
    unawaited(stopAll());
    super.dispose();
  }
}

class ObservationPanel extends StatelessWidget {
  const ObservationPanel({
    super.key,
    required this.source,
    required this.language,
  });
  final Observation source;
  final String language;
  String t(String zh, String en) => language == 'en' ? en : zh;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: source,
    builder: (context, _) => Card(
      child: ExpansionTile(
        title: Text(t('摄像头与麦克风', 'Camera & microphone')),
        subtitle: Text(
          t('默认关闭，停止时释放设备', 'Off by default; stop releases devices'),
        ),
        childrenPadding: const EdgeInsets.all(16),
        children: [
          Text(
            t(
              '开启后，聊天请求会附带亮度和音量摘要。摄像头画面只在你开启“发送画面给模型”后随请求发送；音频不上传、不保存。',
              'When enabled, chat requests include brightness and sound level. Images are shared only with the separate image-sharing switch. Audio is never uploaded or saved.',
            ),
          ),
          SwitchListTile(
            value: source.camera != null,
            onChanged: source.cameraStarting
                ? null
                : (v) => v
                      ? unawaited(source.startCamera())
                      : unawaited(source.stopCamera()),
            title: Text(t('摄像头本机预览', 'Local camera preview')),
            subtitle: Text(source.cameraStatus),
          ),
          if (source.camera != null)
            SizedBox(height: 160, child: source.camera!.preview()),
          SwitchListTile(
            value: source.shareImage,
            onChanged: source.camera == null
                ? null
                : (v) {
                    source.shareImage = v;
                    source.changed();
                  },
            title: Text(t('发送画面给模型', 'Send images to model')),
            subtitle: Text(
              t(
                '需要支持图片的模型；每个请求最多一张缩略图',
                'Requires a vision model; one thumbnail per request',
              ),
            ),
          ),
          SwitchListTile(
            value: source.microphone != null,
            onChanged: source.micStarting
                ? null
                : (v) => v
                      ? unawaited(source.startMic())
                      : unawaited(source.stopMic()),
            title: Text(t('麦克风音量测量', 'Microphone level meter')),
            subtitle: Text(source.microphoneStatus),
          ),
          if (source.decibels != null)
            LinearProgressIndicator(
              value: ((source.decibels! + 60) / 60).clamp(0, 1),
            ),
          Text(source.summary),
        ],
      ),
    ),
  );
}
