import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'api_model_provider.dart';
import 'network_diagnostics.dart';
import 'venice_route.dart';

const veniceTtsModel = 'tts-xai-v1';
const veniceTtsVoices = {'eve', 'ara', 'rex', 'sal'};
const veniceTtsMaxBytes = 16 * 1024 * 1024;

/// One cancellable speech generation at a time. Paid requests are never retried.
/// Only the visible assistant reply should be passed here, not control receipts.
class VeniceTtsClient {
  VeniceTtsClient({
    required this.apiKey,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 60),
  }) : endpoint = endpoint ?? VeniceRoute.endpoint('audio/speech') {
    final uri = this.endpoint;
    final official =
        uri.scheme == 'https' &&
        uri.host == 'api.venice.ai' &&
        uri.port == 443 &&
        uri.path == '/api/v1/audio/speech';
    final fixture =
        uri.scheme == 'http' &&
        const ['127.0.0.1', 'localhost', '::1'].contains(uri.host);
    if (uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !(official ||
            fixture ||
            VeniceRoute.accepts(uri) &&
                uri.path == VeniceRoute.endpoint('audio/speech').path)) {
      throw const ModelServiceException('朗读服务地址无效。');
    }
    if (apiKey.trim().isEmpty ||
        apiKey.length > 4096 ||
        apiKey.contains('\n') ||
        apiKey.contains('\r')) {
      throw const ModelServiceException('密钥格式不正确。');
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive');
    }
  }

  final String apiKey;
  final Uri endpoint;
  final Duration timeout;
  HttpClient? _client;
  bool _cancelled = false;
  Completer<void>? _cancellation;
  Future<void> Function(Uint8List)? onAudioChunk;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
    if (!(_cancellation?.isCompleted ?? true)) _cancellation!.complete();
  }

  Future<Uint8List> synthesize(
    String text, {
    String voice = 'eve',
    double speed = 1,
  }) async {
    if (_cancelled) throw const ModelServiceException('朗读已取消。');
    if (_client != null) throw const ModelServiceException('正在生成语音，请稍候。');
    final input = text.trim();
    if (input.isEmpty || input.runes.length > 4096) {
      throw const ModelServiceException('朗读文字须为 1–4096 个字符。');
    }
    if (!veniceTtsVoices.contains(voice) ||
        !speed.isFinite ||
        speed < 0.7 ||
        speed > 1.5) {
      throw const ModelServiceException('朗读音色或语速无效，请重新选择。');
    }
    final lease = VeniceRoute.lease(endpoint, apiKey);
    final client = lease.client..connectionTimeout = timeout;
    var reusable = false;
    _client = client;
    final cancellation = Completer<void>();
    _cancellation = cancellation;
    final trace = NetworkTrace('朗读');
    trace.mark(lease.reused ? '复用网络客户端' : '新建网络客户端');
    final onChunk = onAudioChunk;
    try {
      final operation = () async {
        final payload = utf8.encode(
          jsonEncode({
            'model': veniceTtsModel,
            'input': input,
            'voice': voice,
            'language': 'zh',
            'response_format': 'mp3',
            'speed': speed,
            'streaming': onChunk != null,
          }),
        );
        await lease.ready;
        final request = await client.postUrl(endpoint);
        trace.attach(request);
        trace.mark('HTTPS 连接成功');
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.acceptHeader, 'audio/mpeg');
        request.contentLength = payload.length;
        request.add(payload);
        trace.mark('发送请求并等待响应');
        final response = await request.close();
        trace.mark('HTTP ${response.statusCode}');
        final relayError = trace.relayResponse(response, endpoint);
        if (response.statusCode != 200) {
          throw ModelServiceException(
            relayError ??
                switch (response.statusCode) {
                  401 || 403 => '朗读服务鉴权或访问权限未通过，请检查服务配置。',
                  402 => '朗读服务余额不足；充值后可手动重试。',
                  400 || 404 || 415 || 422 => '朗读服务未接受模型、音色或音频格式，请复制连接诊断。',
                  413 => '朗读文字超过服务大小限制。',
                  429 => '朗读请求过于频繁，请稍后手动重试。',
                  >= 300 && < 400 => '朗读服务要求重定向，密钥与文字未转发。',
                  _ => '朗读服务返回 HTTP ${response.statusCode}；可手动重试，不会自动重试扣费。',
                },
            code: 'tts_http_${response.statusCode}',
          );
        }
        final mime = response.headers.contentType?.mimeType;
        if (!const {
          'audio/mpeg',
          'audio/mp3',
          'application/octet-stream',
        }.contains(mime)) {
          throw const ModelServiceException('朗读服务未返回 MP3 音频，请复制连接诊断。');
        }
        if (response.contentLength > veniceTtsMaxBytes) {
          throw const ModelServiceException('朗读音频过大，请缩短文字后重试。');
        }
        trace.mark('读取音频');
        final bytes = BytesBuilder(copy: false);
        var prefixSent = false;
        await for (final chunk in response) {
          if (bytes.length + chunk.length > veniceTtsMaxBytes) {
            throw const ModelServiceException('朗读音频过大，请缩短文字后重试。');
          }
          bytes.add(chunk);
          if (_cancelled || !identical(_client, client)) {
            throw const ModelServiceException('朗读已取消。');
          }
          if (onChunk != null) {
            if (!prefixSent && bytes.length >= 32) {
              final prefix = bytes.toBytes();
              if (!_isMp3(prefix)) {
                throw const ModelServiceException('朗读服务返回了无效音频。');
              }
              prefixSent = true;
              trace.mark('首段音频');
              await onChunk(prefix);
            } else if (prefixSent) {
              await onChunk(Uint8List.fromList(chunk));
            }
          }
        }
        final audio = bytes.takeBytes();
        if (!_isMp3(audio)) {
          throw const ModelServiceException('朗读服务返回了无效音频，请手动重试。');
        }
        if (_cancelled) throw const ModelServiceException('朗读已取消。');
        reusable = true;
        trace.mark('成功 · ${audio.length} 字节');
        return audio;
      }();
      return await Future.any<Uint8List>([
        operation,
        cancellation.future.then<Uint8List>(
          (_) => throw const ModelServiceException('朗读已取消。'),
        ),
      ]).timeout(timeout);
    } on ModelServiceException {
      trace.mark(_cancelled ? '已取消' : '请求未完成（${trace.stage}）');
      if (_cancelled) throw const ModelServiceException('朗读已取消。');
      rethrow;
    } on TimeoutException {
      VeniceRoute.connections.invalidate();
      trace.mark('超时（${trace.stage}）');
      throw const ModelServiceException('朗读超时；可手动重试，已发送的请求可能计费。');
    } on HandshakeException {
      VeniceRoute.connections.invalidate();
      trace.mark('TLS 安全连接失败');
      throw ModelServiceException(
        _cancelled ? '朗读已取消。' : '朗读 HTTPS 安全连接失败，请检查网络和手机时间。',
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
      trace.mark(_cancelled ? '已取消' : '网络连接失败');
      throw ModelServiceException(
        _cancelled ? '朗读已取消。' : '无法连接朗读服务，请检查当前直连或中继链路。',
      );
    } catch (_) {
      trace.mark(_cancelled ? '已取消' : '响应未完成');
      throw ModelServiceException(
        _cancelled ? '朗读已取消。' : '朗读连接中断或音频格式不兼容，请手动重试。',
      );
    } finally {
      lease.release(reusable: reusable && !_cancelled);
      if (identical(_client, client)) _client = null;
      if (identical(_cancellation, cancellation)) _cancellation = null;
    }
  }

  static bool _isMp3(Uint8List bytes) {
    if (bytes.length < 32) return false;
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
      return bytes[3] >= 2 && bytes[3] <= 4;
    }
    // MPEG audio sync, supported version and Layer III, non-reserved bitrate.
    return bytes[0] == 0xff &&
        (bytes[1] & 0xe0) == 0xe0 &&
        (bytes[1] & 0x18) != 0x08 &&
        (bytes[1] & 0x06) == 0x02 &&
        (bytes[2] & 0xf0) != 0xf0 &&
        (bytes[2] & 0x0c) != 0x0c;
  }
}
