import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../realtime_probe.dart';
import 'access_store.dart';

/// Private beta relay. Device authorization and execution stay on the client.
class VoiceService {
  VoiceService(
    this.store, {
    required this.adminToken,
    this.provider,
    ProbeConnect? connect,
    this.reservation = 50000,
    this.sessionDuration = const Duration(minutes: 3),
  }) : connect = connect ?? connectProbeSocket;
  final AccessStore store;
  final String adminToken;
  final ProbeConfig? provider;
  final ProbeConnect connect;
  final int reservation;
  final Duration sessionDuration;
  late HttpServer server;
  HttpServer? adminServer;
  final Map<String, _Relay> _active = {};
  final Set<String> _pending = {};
  final Set<Future<void>> _requests = {};
  final Map<String, int> diagnostics = {};
  final Map<String, List<DateTime>> _attempts = {};
  bool _closed = false;
  Future<void> start({
    int port = 0,
    InternetAddress? address,
    SecurityContext? tls,
  }) async {
    if (adminToken.length < 32) throw StateError('admin_token_required');
    final bind = address ?? InternetAddress.loopbackIPv4;
    if (!bind.isLoopback && tls == null) {
      throw StateError('public_listener_requires_tls');
    }
    server = tls == null
        ? await HttpServer.bind(bind, port)
        : await HttpServer.bindSecure(bind, port, tls);
    void listen(HttpServer listener) => listener.listen((req) {
      final work = _handle(req);
      _requests.add(work);
      unawaited(
        work
            .whenComplete(() => _requests.remove(work))
            .catchError((Object _) {}),
      );
    });
    if (tls != null) {
      try {
        adminServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          int.parse(Platform.environment['HAPTICS_ADMIN_PORT'] ?? '8791'),
        );
      } catch (_) {
        await server.close(force: true);
        rethrow;
      }
    }
    listen(server);
    if (adminServer != null) listen(adminServer!);
  }

  String bearer(HttpRequest req) {
    final value = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    return value.startsWith('Bearer ') ? value.substring(7) : '';
  }

  Future<void> json(
    HttpRequest req,
    Map<String, dynamic> body, [
    int status = 200,
  ]) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.headers.set('Cache-Control', 'no-store');
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<Map<String, dynamic>> body(HttpRequest req) async {
    if (req.headers.contentType?.mimeType != 'application/json') {
      throw const FormatException('json');
    }
    final bytes = <int>[];
    await for (final chunk in req.timeout(const Duration(seconds: 5))) {
      if (bytes.length + chunk.length > 8192) {
        throw const FormatException('size');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  bool rateAllowed(String ip) {
    final now = DateTime.now();
    _attempts.removeWhere(
      (_, v) => v.isEmpty || now.difference(v.last).inSeconds > 60,
    );
    if (!_attempts.containsKey(ip) && _attempts.length >= 1000) return false;
    final list = _attempts.putIfAbsent(ip, () => []);
    list.removeWhere((v) => now.difference(v).inSeconds >= 60);
    if (list.length >= 30) return false;
    list.add(now);
    return true;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (_closed) {
        await json(req, {'error': 'service_stopping'}, 503);
        return;
      }
      // Native clients only: no browser cookies, CORS or bearer in URLs.
      if (req.headers.value('origin') != null || req.uri.hasQuery) {
        await json(req, {'error': 'request_denied'}, 403);
        return;
      }
      final path = req.uri.path;
      if (path == '/health' && req.method == 'GET') {
        await json(req, {
          'ok': true,
          'provider_configured': provider != null,
          'protocol': 1,
        });
        return;
      }
      if (path.startsWith('/admin/')) {
        if ((adminServer != null &&
                req.connectionInfo?.localPort != adminServer!.port) ||
            req.connectionInfo?.remoteAddress.isLoopback != true ||
            digest(bearer(req)) != digest(adminToken)) {
          await json(req, {'error': 'denied'}, 403);
          return;
        }
        if (path == '/admin/status' && req.method == 'GET') {
          await json(req, {
            ...store.summary(),
            'active': _active.length,
            'pending': _pending.length,
            'model': ProbeConfig.model,
            'diagnostics': diagnostics,
          });
          return;
        }
        if (req.method != 'POST') {
          await json(req, {'error': 'method'}, 405);
          return;
        }
        final b = await body(req);
        if (path == '/admin/invites') {
          await json(req, {
            'invites': await store.createInvites(b['count'] as int),
          });
          return;
        }
        if (path == '/admin/manage') {
          await store.manage(b);
          await json(req, {'ok': true});
          return;
        }
        if (path == '/admin/recover') {
          await json(req, await store.recover(b['id'] as String));
          return;
        }
        await json(req, {'error': 'not_found'}, 404);
        return;
      }
      if (!rateAllowed(
        req.connectionInfo?.remoteAddress.address ?? 'unknown',
      )) {
        await json(req, {'error': 'rate_limit'}, 429);
        return;
      }
      if (path == '/v1/redeem' && req.method == 'POST') {
        final b = await body(req);
        await json(req, await store.redeem(b['code'] as String));
        return;
      }
      final token = bearer(req), id = store.authenticate(bearer(req));
      if (id == null ||
          (id == 'local-owner' &&
              (req.connectionInfo?.remoteAddress.isLoopback != true ||
                  !server.address.isLoopback))) {
        await json(req, {'error': 'access_denied'}, 401);
        return;
      }
      if (path == '/v1/me' && req.method == 'GET') {
        await json(req, store.account(id));
        return;
      }
      if (path != '/v1/realtime' ||
          req.method != 'GET' ||
          !WebSocketTransformer.isUpgradeRequest(req)) {
        await json(req, {'error': 'not_found'}, 404);
        return;
      }
      if (provider == null) {
        await json(req, {'error': 'provider_not_configured'}, 503);
        return;
      }
      if (_active.containsKey(id) ||
          _pending.contains(id) ||
          _active.length + _pending.length >= 5) {
        await json(req, {'error': 'concurrency_limit'}, 409);
        return;
      }
      _pending.add(id);
      var reserved = false, transferred = false;
      WebSocket? upstream;
      try {
        await store.reserve(id, reservation);
        reserved = true;
        var expired = false;
        final opening = connect(provider!.uri, provider!.key);
        unawaited(
          opening.then((socket) {
            if (expired) unawaited(socket.close());
          }, onError: (Object _) {}),
        );
        try {
          upstream = await opening.timeout(const Duration(seconds: 15));
        } catch (error) {
          // Keep only the exception class and HTTP status, never its URL/body.
          final status = RegExp(r'HTTP status code: (\d{3})')
              .firstMatch('$error')
              ?.group(1);
          final reason =
              'upstream_${error.runtimeType}${status == null ? '' : '_http_$status'}';
          diagnostics[reason] = (diagnostics[reason] ?? 0) + 1;
          rethrow;
        } finally {
          expired = true;
        }
        if (_closed || store.authenticate(token) != id) {
          throw StateError('access_revoked');
        }
        final downstream = await WebSocketTransformer.upgrade(req);
        final relay = _Relay(this, id, token, downstream, upstream);
        _active[id] = relay;
        transferred = true;
        relay.start();
      } finally {
        _pending.remove(id);
        if (!transferred) {
          await upstream?.close();
          if (reserved) await store.settle(id, reservation, 0, 0, 0);
        }
      }
    } catch (_) {
      try {
        await json(req, {
          'error': 'request_failed_check_invite_quota_or_provider',
        }, 400);
      } catch (_) {}
    }
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait(
      _active.values.toList().map((r) => r.close('service_shutdown')),
    );
    await server.close(force: true);
    await adminServer?.close(force: true);
    await Future.wait(_requests.toList());
  }
}

class _Relay {
  _Relay(this.service, this.user, this.token, this.client, this.upstream);
  final VoiceService service;
  final String user, token;
  final WebSocket client, upstream;
  Timer? timer;
  bool closed = false, configured = false, unknownUsage = false;
  int input = 0, output = 0, total = 0, audioBytes = 0, messages = 0;
  final watch = Stopwatch()..start();
  int windowBytes = 0, windowMessages = 0;
  DateTime windowStart = DateTime.now();
  final seen = <String>{}, pendingResponses = <String>{};
  final cancellations = <String>{};
  void start() {
    client.pingInterval = const Duration(seconds: 5);
    upstream.pingInterval = const Duration(seconds: 10);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!closed && client.readyState == WebSocket.open) {
        client.add(jsonEncode({'type': 'service.heartbeat'}));
      }
      if (service._closed) {
        unawaited(close('service_shutdown'));
      } else if (service.store.authenticate(token) != user) {
        unawaited(close('access_revoked'));
      } else if (watch.elapsed >= service.sessionDuration) {
        unawaited(close('session_limit'));
      } else if (service.store.data['used'] > service.store.data['budget'] ||
          service.store.users[user]['used'] >
              service.store.users[user]['quota']) {
        unawaited(close('quota_exhausted'));
      }
    });
    client.listen(
      fromClient,
      onDone: () => unawaited(close('client_closed')),
      onError: (Object _) => unawaited(close('client_error')),
    );
    upstream.listen(
      fromProvider,
      onDone: () => unawaited(close('provider_closed')),
      onError: (Object _) => unawaited(close('provider_error')),
    );
  }

  void fromClient(dynamic raw) {
    if (closed) return;
    try {
      if (raw is! String || raw.length > 65536) {
        throw const FormatException('frame');
      }
      if (DateTime.now().difference(windowStart).inSeconds >= 1) {
        windowStart = DateTime.now();
        windowBytes = 0;
        windowMessages = 0;
      }
      if (++windowMessages > 100 || ++messages > 18000) {
        throw const FormatException('rate');
      }
      final e = jsonDecode(raw) as Map<String, dynamic>;
      final type = e['type'];
      if (type == 'response.cancel' && e['event_id'] is String) {
        cancellations.add(e['event_id'] as String);
        if (cancellations.length > 20) {
          cancellations.remove(cancellations.first);
        }
      }
      if (type == 'session.update') {
        if (configured) throw const FormatException('already_configured');
        configured = true;
        final session = e['session'] as Map<String, dynamic>;
        // Fixed provider/model/tool contract. No client-provided upstream URL/key.
        if (jsonEncode(session).length > 14000) {
          throw const FormatException('session_size');
        }
        session['max_tokens'] = 512;
        session['modalities'] = ['text', 'audio'];
        session['input_audio_format'] = 'pcm';
        session['output_audio_format'] = 'pcm';
      } else if (!configured) {
        throw const FormatException('not_ready');
      } else if (type == 'input_audio_buffer.append') {
        final bytes = base64Decode(e['audio'] as String);
        windowBytes += bytes.length;
        audioBytes += bytes.length;
        if (bytes.length.isOdd ||
            bytes.length > 32000 ||
            windowBytes > 96000 ||
            audioBytes > 16000 * 2 * service.sessionDuration.inSeconds) {
          throw const FormatException('audio_limit');
        }
      } else if (![
        'input_audio_buffer.clear',
        'response.cancel',
        'response.create',
        'conversation.item.create',
        'conversation.item.truncate',
      ].contains(type)) {
        throw const FormatException('event_not_allowed');
      }
      // Never accept token-limit or modality overrides on response.create.
      if (type == 'response.create') e.remove('response');
      upstream.add(jsonEncode(e));
    } catch (_) {
      unawaited(close('invalid_client_event'));
    }
  }

  void fromProvider(dynamic raw) {
    if (closed) return;
    try {
      if (raw is! String || raw.length > 1024 * 1024) {
        throw const FormatException('provider_frame');
      }
      final e = jsonDecode(raw) as Map<String, dynamic>;
      if (e['type'] == 'response.created') {
        pendingResponses.add(e['response']['id'] as String);
      }
      if (e['type'] == 'response.done') {
        final r = e['response'] as Map<String, dynamic>, id = r['id'] as String;
        pendingResponses.remove(id);
        if (seen.add(id)) {
          final usage = r['usage'];
          if (usage is Map &&
              usage['input_tokens'] is int &&
              usage['output_tokens'] is int &&
              usage['total_tokens'] is int &&
              usage['input_tokens'] >= 0 &&
              usage['output_tokens'] >= 0 &&
              usage['total_tokens'] >= 0) {
            input += usage['input_tokens'] as int;
            output += usage['output_tokens'] as int;
            total += usage['total_tokens'] as int;
          } else {
            unknownUsage = true;
          }
        }
        if (total >= service.reservation || seen.length >= 100) {
          unawaited(close('quota_exhausted'));
          return;
        }
      }
      if (e['type'] == 'error') {
        final error = e['error'];
        if (error is Map &&
            cancellations.remove(error['event_id']) &&
            error['message'] is String &&
            RegExp(
              r'no active response|already (?:completed|cancelled|canceled)',
              caseSensitive: false,
            ).hasMatch(error['message'] as String)) {
          return;
        }
        // The provider can echo secrets or content in error descriptions.
        client.add(
          jsonEncode({
            'type': 'error',
            'error': {'code': 'provider_error', 'message': 'provider_error'},
          }),
        );
        unawaited(close('provider_error'));
        return;
      }
      client.add(raw);
    } catch (_) {
      unawaited(close('invalid_provider_event'));
    }
  }

  Future<void>? _closing;
  Future<void> close(String reason) => _closing ??= _finishClose(reason);
  Future<void> _finishClose(String reason) async {
    closed = true;
    timer?.cancel();
    service.diagnostics[reason] = (service.diagnostics[reason] ?? 0) + 1;
    if (client.readyState == WebSocket.open) {
      client.add(jsonEncode({'type': 'service.closed', 'reason': reason}));
    }
    await Future.wait(
      [client.close(), upstream.close()].map(
        (f) => f
            .timeout(const Duration(seconds: 2), onTimeout: () => null)
            .catchError((Object _) {}),
      ),
    );
    try {
      // Missing usage or an interrupted generation conservatively consumes its reservation.
      final charged =
          unknownUsage ||
              pendingResponses.isNotEmpty ||
              (audioBytes > 0 && seen.isEmpty)
          ? service.reservation
          : total;
      await service.store.settle(
        user,
        service.reservation,
        charged > total ? charged : total,
        input,
        output,
      );
    } catch (_) {
      // Reservation remains charged on persistence failure. Fail closed.
      service._closed = true;
    } finally {
      service._active.remove(user);
    }
  }
}
