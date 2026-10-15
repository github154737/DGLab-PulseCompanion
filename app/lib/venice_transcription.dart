import 'venice_route.dart';
import 'network_diagnostics.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'api_model_provider.dart';

const veniceSpeechModel = 'stt-xai-v1';
const veniceTextModel = 'venice-uncensored-1-2';

/// Valid STT response with no words, not a transport or schema failure.
class NoSpeechDetected extends ModelServiceException {
  const NoSpeechDetected() : super('未识别到有效文字，请靠近麦克风重新说话。', code: 'no_speech');
}

/// 16 kHz mono, signed little-endian PCM16. The audio never needs a disk file.
Uint8List pcmToWav(Uint8List pcm) {
  if (pcm.isEmpty || pcm.length.isOdd || pcm.length > 16000 * 2 * 60) {
    throw const ModelServiceException('录音为空或超过 60 秒，请重新录音。');
  }
  final bytes = Uint8List(44 + pcm.length);
  final header = ByteData.sublistView(bytes);
  void tag(int offset, String text) =>
      bytes.setRange(offset, offset + 4, ascii.encode(text));
  tag(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}

class VeniceTranscriber {
  VeniceTranscriber({
    required this.apiKey,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 60),
  }) : endpoint = endpoint ?? VeniceRoute.endpoint('audio/transcriptions') {
    final uri = this.endpoint;
    if (uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !(VeniceRoute.accepts(uri) ||
            uri.scheme == 'https' && uri.host == 'api.venice.ai' ||
            uri.scheme == 'http' &&
                ['127.0.0.1', 'localhost', '::1'].contains(uri.host))) {
      throw const ModelServiceException('语音服务地址无效。');
    }
    if (apiKey.isEmpty ||
        apiKey.length > 4096 ||
        apiKey.contains('\n') ||
        apiKey.contains('\r')) {
      throw const ModelServiceException('密钥格式不正确。');
    }
  }
  final String apiKey;
  final Uri endpoint;
  final Duration timeout;
  HttpClient? _client;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<String> transcribe(Uint8List wav) async {
    if (_cancelled) throw const ModelServiceException('转写已取消。');
    if (wav.length < 46 ||
        wav.length > 1920044 ||
        ascii.decode(wav.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
        ascii.decode(wav.sublist(8, 12), allowInvalid: true) != 'WAVE') {
      throw const ModelServiceException('录音格式无效，请重新录音。');
    }
    if (_client != null) throw const ModelServiceException('正在转写，请稍候。');
    final lease = VeniceRoute.lease(endpoint, apiKey);
    final client = lease.client..connectionTimeout = timeout;
    var reusable = false;
    _client = client;
    final trace = NetworkTrace('转写');
    trace.mark('音频 ${wav.length} 字节 · PCM ${(wav.length - 44) ~/ 32}ms');
    trace.mark(lease.reused ? '复用网络客户端' : '新建网络客户端');
    try {
      return await (() async {
        final boundary =
            'aihaptics-${List.generate(24, (_) => Random.secure().nextInt(16).toRadixString(16)).join()}';
        final head = utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="model"\r\n\r\n$veniceSpeechModel\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="timestamps"\r\n\r\nfalse\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="speech.wav"\r\n'
          'Content-Type: audio/wav\r\n\r\n',
        );
        final tail = utf8.encode('\r\n--$boundary--\r\n');
        await lease.ready;
        final request = await client.postUrl(endpoint);
        trace.attach(request);
        trace.mark('HTTPS 连接成功');
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary',
        );
        request.contentLength = head.length + wav.length + tail.length;
        request.add(head);
        request.add(wav);
        request.add(tail);
        trace.mark('发送请求并等待响应');
        final response = await request.close();
        trace.mark('HTTP ${response.statusCode}');
        final relayError = trace.relayResponse(response, endpoint);
        if (response.statusCode != 200) {
          throw ModelServiceException(
            relayError ??
                switch (response.statusCode) {
                  401 || 403 => '语音服务鉴权失败，请检查 Venice 密钥和权限。',
                  402 => '语音服务余额不足；充值后手动重试，不会自动扣费重试。',
                  404 => '语音接口或 stt-xai-v1 模型不可用。',
                  413 => '录音超出服务大小限制，请缩短后重试。',
                  415 || 422 => '语音服务未接受录音格式，请重新录音。',
                  429 => '语音服务请求过于频繁，请稍后手动重试。',
                  >= 300 && < 400 => '语音服务要求重定向，密钥和录音未转发。',
                  _ => '语音服务返回 HTTP ${response.statusCode}，请稍后重试。',
                },
          );
        }
        final body = BytesBuilder();
        await for (final part in response) {
          if (body.length + part.length > 65536) {
            throw const ModelServiceException('转写响应过大。');
          }
          body.add(part);
        }
        trace.mark('读取与解析响应');
        final decoded = jsonDecode(utf8.decode(body.takeBytes()));
        final text = decoded is Map ? decoded['text'] : null;
        if (text is! String) {
          throw const ModelServiceException(
            '转写服务缺少有效文字字段，请复制诊断。',
            code: 'stt_schema',
          );
        }
        if (text.trim().isEmpty) {
          reusable = true;
          trace.mark('有效响应 · 无可识别文字 · 不重试本段录音');
          throw const NoSpeechDetected();
        }
        if (text.length > 2000) {
          throw const ModelServiceException('转写超过 2000 字，请分段录音。');
        }
        reusable = true;
        trace.mark('成功 · ${text.trim().runes.length} 字');
        return text.trim();
      })().timeout(timeout);
    } on NoSpeechDetected {
      rethrow;
    } on ModelServiceException catch (error) {
      trace.mark('错误类别 ${error.code}');
      trace.mark('请求未完成（${trace.stage}）');
      rethrow;
    } on TimeoutException {
      VeniceRoute.connections.invalidate();
      trace.mark('超时（${trace.stage}）');
      throw const ModelServiceException('转写超时；可手动重试，已发送的请求可能计费。');
    } on HandshakeException {
      VeniceRoute.connections.invalidate();
      trace.mark('TLS 安全连接失败');
      throw ModelServiceException(
        _cancelled ? '请求已取消。' : 'HTTPS 安全连接失败，请检查手机时间与网络；可在“我的”中打开连接诊断。',
      );
    } on HttpException {
      VeniceRoute.connections.invalidate();
      trace.mark(_cancelled ? '已取消' : 'HTTP 响应中断');
      throw ModelServiceException(
        _cancelled ? '请求已取消。' : '网络切换或服务连接中断，本次响应未完成；可手动重试。',
        code: _cancelled ? 'cancelled' : 'http_transport',
      );
    } on SocketException {
      VeniceRoute.connections.invalidate();
      trace.mark('网络连接失败');
      throw ModelServiceException(
        _cancelled ? '请求已取消。' : '无法连接语音服务，请检查当前直连或中继链路；录音保留，可手动重试。',
      );
    } on FormatException {
      trace.mark('响应格式错误');
      throw const ModelServiceException('转写服务响应格式无效，请复制连接诊断。');
    } catch (_) {
      throw ModelServiceException(_cancelled ? '转写已取消。' : '转写连接失败或响应格式不兼容。');
    } finally {
      lease.release(reusable: reusable && !_cancelled);
      _client = null;
    }
  }
}
