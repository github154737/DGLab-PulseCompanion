import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Standalone Dart deployment deliberately does not depend on Flutter package resolution.
// ignore: avoid_relative_lib_imports
import '../lib/http_connection_pool.dart';

/// LAN-only evaluation relay. No conversation/audio/header logging or storage.
class VeniceRelay {
  VeniceRelay({
    required this.key,
    required this.token,
    this.upstream,
    this.proxy,
    this.onEvent,
    this.clientFactory,
    this.connectTimeout = const Duration(seconds: 6),
    this.textBudget = const Duration(seconds: 26),
    this.audioBudget = const Duration(seconds: 54),
    this.retryDelay = const Duration(milliseconds: 250),
  });
  final String key, token;
  final Uri? upstream; // Loopback fixtures only; CLI always uses Venice.
  final String? proxy;
  final void Function(Map<String, Object>)? onEvent;
  final HttpClient Function()? clientFactory;
  final Duration connectTimeout, textBudget, audioBudget, retryDelay;
  final connections = HttpConnectionPool();
  void dispose() => connections.invalidate();
  int active = 0;
  final List<DateTime> starts = [];
  // A voice turn can include transcription, control, chat and speech requests.
  // Keep a finite LAN quota without cutting off normal continuous conversation.
  static const maxStartsPerMinute = 60;
  static const routes = {
    '/api/v1/models': 'GET',
    '/api/v1/chat/completions': 'POST',
    '/api/v1/audio/transcriptions': 'POST',
    '/api/v1/audio/speech': 'POST',
  };
  bool authorized(String value) {
    final expected = 'Bearer $token';
    var diff = value.length ^ expected.length;
    for (var i = 0; i < expected.length; i++) {
      diff |=
          expected.codeUnitAt(i) ^ (i < value.length ? value.codeUnitAt(i) : 0);
    }
    return diff == 0;
  }

  Future<Uint8List> bounded(Stream<List<int>> stream, int limit) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > limit) throw const FormatException();
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    // Rejecting an unread body must never leave a reusable connection behind.
    response.persistentConnection = false;
    HttpClient? client;
    HttpClientLease? lease;
    var counted = false;
    var streamOutput = false;
    var responseStarted = false;
    final clock = Stopwatch()..start();
    final rawId = request.headers.value('x-aihaptics-request-id') ?? '';
    final requestId = RegExp(r'^[a-zA-Z0-9-]{1,64}$').hasMatch(rawId)
        ? rawId
        : 'untracked';
    var stage = 'client_upload';
    var attempt = 0;
    var upstreamStatus = 0, upstreamBytes = 0, upstreamHeadersMs = 0;
    var detail = '';
    final audio = request.uri.path.endsWith('/transcriptions');
    final speech = request.uri.path.endsWith('/speech');
    Duration remaining() {
      final left = (audio || speech ? audioBudget : textBudget) - clock.elapsed;
      if (left <= Duration.zero) throw TimeoutException('relay_budget');
      return left;
    }

    final kind = request.uri.path.endsWith('/transcriptions')
        ? 'transcription'
        : speech
        ? 'speech'
        : 'text';
    Future<void> fail(
      int status, [
      String code = 'relay_rejected',
      int? osCode,
    ]) async {
      onEvent?.call({
        'kind': kind,
        'request_id': requestId,
        'stage': stage,
        'status': status,
        'code': code,
        'attempts': attempt,
        'ms': clock.elapsedMilliseconds,
        'upstream_status': upstreamStatus,
        'upstream_bytes': upstreamBytes,
        'upstream_headers_ms': upstreamHeadersMs,
        'response_started': responseStarted,
        'detail': detail,
        'os_code': ?osCode,
      });
      if (responseStarted) {
        // Once bytes have reached the caller never splice JSON into MP3/SSE or
        // finish a truncated stream as if it succeeded. Force a transport error.
        try {
          response.addError(const HttpException('upstream_stream_interrupted'));
        } catch (_) {}
        return;
      }
      try {
        response.statusCode = status;
        response.headers.set('X-AIHaptics-Relay-Error', code);
        response.headers.set('X-AIHaptics-Relay-Stage', stage);
        response.headers.set('X-AIHaptics-Relay-Attempts', '$attempt');
        if (detail.isNotEmpty) {
          response.headers.set('X-AIHaptics-Relay-Detail', detail);
        }
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'error': {'message': 'relay_http_$status'},
          }),
        );
      } on HttpException {
        // A phone may cancel while the upstream request is still finishing.
      } on SocketException {
        // Do not let a disconnected caller terminate the relay service.
      } on StateError {
        // Headers/response may already have been closed by the transport.
      }
    }

    try {
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('X-AIHaptics-Relay-Version', '0.12.3');
      response.headers.set('X-AIHaptics-Request-Id', requestId);
      response.headers.set(
        'X-AIHaptics-Relay-Capabilities',
        'speech,speech-stream,chat-stream',
      );
      if (!authorized(request.headers.value('authorization') ?? '')) {
        await fail(401);
        return;
      }
      // Local authenticated readiness only; never calls a paid/upstream API.
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/health' &&
          !request.uri.hasQuery) {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'ready': true, 'version': '0.12.3'}));
        return;
      }
      if (request.uri.hasQuery || routes[request.uri.path] != request.method) {
        await fail(404);
        return;
      }
      final now = DateTime.now();
      starts.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
      if (active >= 2 || starts.length >= maxStartsPerMinute) {
        await fail(429);
        return;
      }
      starts.add(now);
      active++;
      counted = true;
      final limit = audio ? 2000000 : 131072;
      if (request.contentLength > limit) {
        await fail(413);
        return;
      }
      final body = await bounded(
        request,
        limit,
      ).timeout(const Duration(seconds: 15));
      final type = request.headers.contentType;
      if (request.method == 'POST') {
        if (audio) {
          if (type?.mimeType != 'multipart/form-data' ||
              !(type?.parameters.containsKey('boundary') ?? false)) {
            await fail(415);
            return;
          }
          final text = latin1.decode(body);
          if (!RegExp(r'name="model"\r\n\r\nstt-xai-v1\r\n').hasMatch(text)) {
            await fail(422);
            return;
          }
        } else if (speech) {
          if (type?.mimeType != 'application/json') {
            await fail(415);
            return;
          }
          final data = jsonDecode(utf8.decode(body));
          const fields = {
            'model',
            'input',
            'voice',
            'language',
            'response_format',
            'speed',
            'streaming',
          };
          if (data is! Map ||
              data.keys.any((key) => !fields.contains(key)) ||
              data['model'] != 'tts-xai-v1' ||
              data['input'] is! String ||
              (data['input'] as String).trim().isEmpty ||
              (data['input'] as String).runes.length > 4096 ||
              !const {'eve', 'ara', 'rex', 'sal'}.contains(data['voice']) ||
              data['language'] != 'zh' ||
              data['response_format'] != 'mp3' ||
              data['streaming'] is! bool ||
              data['speed'] is! num ||
              !(data['speed'] as num).isFinite ||
              data['speed'] < 0.7 ||
              data['speed'] > 1.5) {
            await fail(422);
            return;
          }
          streamOutput = data['streaming'] == true;
        } else {
          final data = jsonDecode(utf8.decode(body));
          if (data is! Map ||
              !const {
                'venice-uncensored-1-2',
                'z-ai-glm-5-3-flash',
              }.contains(data['model']) ||
              data['messages'] is! List ||
              (data['stream'] != null && data['stream'] is! bool) ||
              data['max_tokens'] is! int ||
              data['max_tokens'] < 1 ||
              data['max_tokens'] > 2400) {
            await fail(422);
            return;
          }
          streamOutput = data['stream'] == true;
        }
      }
      final target = (upstream ?? Uri.parse('https://api.venice.ai')).replace(
        path: request.uri.path,
      );
      Future<bool> retry(String code) async {
        // TTS is a paid generation: never replay it, including HTTP failures.
        if (speech) return false;
        // At most one retry; no replay after an ambiguous post-upload timeout.
        // A received 502/503/504 is retryable, but the supplier may still bill it.
        if (attempt >= 2 ||
            starts.length >= maxStartsPerMinute ||
            remaining() <= retryDelay) {
          return false;
        }
        client?.close(force: true);
        client = null;
        onEvent?.call({
          'kind': kind,
          'request_id': requestId,
          'stage': stage,
          'code': code,
          'attempts': attempt,
          'ms': clock.elapsedMilliseconds,
        });
        starts.add(DateTime.now());
        await Future<void>.delayed(retryDelay);
        return true;
      }

      for (attempt = 1; attempt <= 2; attempt++) {
        remaining();
        lease = connections.acquire(
          target.origin,
          clientFactory ?? HttpClient.new,
        );
        client = lease.client..connectionTimeout = connectTimeout;
        var reusable = false;
        if (proxy != null && proxy!.isNotEmpty) {
          client!.findProxy = (_) => 'PROXY $proxy';
        }
        try {
          await lease.ready;
          stage = 'upstream_connect';
          final left = remaining();
          final outgoing = await client!
              .openUrl(request.method, target)
              .timeout(left < connectTimeout ? left : connectTimeout);
          outgoing.followRedirects = false;
          outgoing.headers.set('Authorization', 'Bearer $key');
          if (type != null) outgoing.headers.contentType = type;
          outgoing.contentLength = body.length;
          // From this point a request may have reached the supplier. Never
          // blindly replay a lost response or a partially read completion.
          stage = 'upstream_response';
          outgoing.add(body);
          final incoming = await outgoing.close().timeout(remaining());
          upstreamStatus = incoming.statusCode;
          upstreamHeadersMs = clock.elapsedMilliseconds;
          if (incoming.statusCode != 200) {
            if ([502, 503, 504].contains(incoming.statusCode) &&
                await retry('retry_upstream_${incoming.statusCode}')) {
              continue;
            }
            await fail(incoming.statusCode, 'upstream_http');
            return;
          }
          stage = 'upstream_read';
          final responseLimit = speech ? 16 * 1024 * 1024 : 1048576;
          if (incoming.contentLength > responseLimit) {
            await fail(502, 'upstream_response_too_large');
            return;
          }
          if (speech &&
              !const {
                'audio/mpeg',
                'audio/mp3',
                'application/octet-stream',
              }.contains(incoming.headers.contentType?.mimeType)) {
            detail = 'audio_content_type';
            await fail(502, 'upstream_audio_invalid');
            return;
          }
          if (streamOutput &&
              (speech ||
                  incoming.headers.contentType?.mimeType ==
                      'text/event-stream')) {
            response.headers.set('X-AIHaptics-Relay-Attempts', '$attempt');
            response.headers.contentType = speech
                ? ContentType('audio', 'mpeg')
                : ContentType('text', 'event-stream');
            response.persistentConnection = request.persistentConnection;
            response.headers.set('X-Accel-Buffering', 'no');
            response.bufferOutput = false;
            var total = 0;
            var prefixValidated = !speech;
            final prefix = BytesBuilder(copy: false);
            await (() async {
              await for (final part in incoming) {
                total += part.length;
                upstreamBytes = total;
                if (total > responseLimit) {
                  throw const FormatException('stream_too_large');
                }
                if (!prefixValidated) {
                  prefix.add(part);
                  if (prefix.length < 32) continue;
                  final first = prefix.takeBytes();
                  if (!_isMp3(first)) {
                    throw const FormatException('invalid_mp3');
                  }
                  prefixValidated = true;
                  responseStarted = true;
                  response.add(first);
                } else {
                  responseStarted = true;
                  response.add(part);
                }
                await response.flush();
              }
              if (!prefixValidated || total == 0) {
                throw const FormatException('empty_stream');
              }
            })().timeout(remaining());
            reusable = true;
            onEvent?.call({
              'kind': kind,
              'request_id': requestId,
              'stage': 'complete',
              'status': 200,
              'code': 'stream_ok',
              'attempts': attempt,
              'ms': clock.elapsedMilliseconds,
            });
            return;
          }
          final result = await bounded(
            incoming,
            responseLimit,
          ).timeout(remaining());
          upstreamBytes = result.length;
          if (speech && !_isMp3(result)) {
            await fail(502, 'upstream_audio_invalid');
            return;
          }
          response.headers.set('X-AIHaptics-Relay-Attempts', '$attempt');
          response.headers.contentType = speech
              ? ContentType('audio', 'mpeg')
              : ContentType.json;
          response.persistentConnection = request.persistentConnection;
          reusable = true;
          response.add(result);
          onEvent?.call({
            'kind': kind,
            'request_id': requestId,
            'stage': 'complete',
            'status': 200,
            'code': 'ok',
            'attempts': attempt,
            'ms': clock.elapsedMilliseconds,
          });
          return;
        } on SocketException {
          if (stage == 'upstream_connect' &&
              await retry('retry_connect_socket')) {
            continue;
          }
          rethrow;
        } on TimeoutException {
          if (stage == 'upstream_connect' &&
              await retry('retry_connect_timeout')) {
            continue;
          }
          rethrow;
        } finally {
          lease.release(reusable: reusable);
          lease = null;
          client = null;
        }
      }
    } on TimeoutException {
      await fail(504, 'timeout');
    } on HandshakeException {
      await fail(502, 'upstream_tls');
    } on SocketException catch (error) {
      await fail(502, 'socket', error.osError?.errorCode);
    } on HttpException {
      await fail(502, 'http_transport');
    } on FormatException catch (error) {
      // Whitelist application-defined reasons; never log a raw payload/message.
      if (const {
        'invalid_mp3',
        'empty_stream',
        'stream_too_large',
      }.contains(error.message)) {
        detail = error.message;
      } else {
        detail = 'format_unspecified';
      }
      await fail(
        stage == 'upstream_read' ? 502 : 422,
        stage == 'upstream_read'
            ? 'upstream_response_invalid'
            : 'relay_rejected',
      );
    } catch (_) {
      await fail(502, 'unexpected');
    } finally {
      lease?.release();
      client?.close(force: true);
      if (counted) active--;
      try {
        await response.close();
      } catch (_) {
        /* disconnected caller */
      }
    }
  }

  static bool _isMp3(Uint8List bytes) {
    if (bytes.length < 32) return false;
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
      return bytes[3] >= 2 && bytes[3] <= 4;
    }
    return bytes[0] == 0xff &&
        (bytes[1] & 0xe0) == 0xe0 &&
        (bytes[1] & 0x18) != 0x08 &&
        (bytes[1] & 0x06) == 0x02 &&
        (bytes[2] & 0xf0) != 0xf0 &&
        (bytes[2] & 0x0c) != 0x0c;
  }
}

Future<void> main(List<String> args) async {
  if (args.length == 2 && args.first == '--check') {
    HttpClient? client;
    try {
      final config = jsonDecode(await File(args[1]).readAsString()) as Map;
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(config['certificate'] as String);
      client = HttpClient(context: context)
        ..connectionTimeout = const Duration(seconds: 2)
        ..findProxy = (_) => 'DIRECT';
      final request = await client
          .getUrl(
            Uri(
              scheme: 'https',
              host: config['host'] as String,
              port: config['port'] as int,
              path: '/api/v1/health',
            ),
          )
          .timeout(const Duration(seconds: 3));
      request.followRedirects = false;
      request.headers.set('Authorization', 'Bearer ${config['token']}');
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200 ||
          (jsonDecode(body) as Map)['ready'] != true) {
        throw StateError('not_ready');
      }
      stdout.writeln('Relay TLS/authentication/readiness check passed.');
    } catch (_) {
      stdout.writeln('Relay readiness check failed.');
      exitCode = 1;
    } finally {
      client?.close(force: true);
    }
    return;
  }
  if (args.length != 1) {
    throw ArgumentError('Expected private configuration file path');
  }
  final config = jsonDecode(await File(args.single).readAsString()) as Map;
  final key = (await File(config['keyFile'] as String).readAsString()).trim();
  final match = RegExp(r'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}')
      .allMatches(key)
      .toList();
  if (match.length != 1) throw StateError('Invalid supplier key file');
  final context = SecurityContext()
    ..useCertificateChain(config['certificate'] as String)
    ..usePrivateKey(config['privateKey'] as String);
  final relay = VeniceRelay(
    key: match.single.group(0)!,
    token: config['token'] as String,
    proxy: config['proxy'] as String?,
    onEvent: (event) => stdout.writeln(
      jsonEncode({'at': DateTime.now().toIso8601String(), ...event}),
    ),
  );
  final server = await HttpServer.bindSecure(
    config['host'] as String,
    config['port'] as int,
    context,
  );
  server.idleTimeout = const Duration(seconds: 20);
  stdout.writeln(
    'Venice LAN relay listening with TLS; request content logging disabled.',
  );
  await for (final request in server) {
    unawaited(relay.handle(request));
  }
}
