import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'realtime_probe.dart';

/// Loopback development probe, not the five-user production service.
class ProbeServer {
  ProbeServer(
    this.core,
    this.assets,
    this.reportFile, {
    this.connector,
    this.credentialLifetime = const Duration(minutes: 20),
  });
  final Duration credentialLifetime;
  final ProbeCore core;
  final Directory assets;
  final File reportFile;
  final ProbeConnect? connector;
  late final HttpServer server;
  late final RealtimeProbe probe;
  WebSocket? _browser;
  Timer? _ticker;
  Timer? _credentialExpiry;
  ProbeConfig? _config;
  bool _paused = false;
  Future<void> _reportWrites = Future<void>.value();
  bool get hasCredentials => _config != null;
  DateTime _lastHeartbeat = DateTime.now();
  final String token = base64Url.encode(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );
  String get origin => 'http://127.0.0.1:${server.port}';

  Future<void> start({int port = 0}) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    probe = RealtimeProbe(core, emit, connect: connector);
    core({'op': 'connect', 'device_id': 'sim_single'});
    server.listen((request) {
      unawaited(_handle(request));
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (_browser == null) return;
      if (!_paused && DateTime.now().difference(_lastHeartbeat).inSeconds > 5) {
        unawaited(
          probe.close(
            message: '页面失去响应，测试已停止',
            reason: 'browser_heartbeat_timeout',
          ),
        );
        unawaited(_browser?.close());
        _browser = null;
      } else {
        emit(probe.state);
      }
    });
  }

  void emit(Map<String, dynamic> event) {
    if (_browser?.readyState == WebSocket.open) {
      _browser!.add(
        jsonEncode({...event, 'credentials_ready': hasCredentials}),
      );
    }
    if (event['type'] == 'closed' &&
        (probe.counts['session_updated'] ?? 0) > 0) {
      unawaited(saveReport().catchError((Object _) {}));
    }
  }

  Future<void> saveReport() {
    final text =
        '${const JsonEncoder.withIndent('  ').convert(probe.report())}\n';
    _reportWrites = _reportWrites.catchError((Object _) {}).then((_) async {
      await reportFile.parent.create(recursive: true);
      await reportFile.writeAsString(text);
    });
    return _reportWrites;
  }

  void forgetCredentials() {
    _credentialExpiry?.cancel();
    _credentialExpiry = null;
    _config = null;
  }

  Future<void> _json(
    HttpRequest req,
    Map<String, dynamic> body, [
    int code = 200,
  ]) async {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<Map<String, dynamic>> _body(HttpRequest req) async {
    if (req.headers.contentType?.mimeType != 'application/json') {
      throw const FormatException('json_required');
    }
    final bytes = <int>[];
    await for (final chunk in req.timeout(const Duration(seconds: 5))) {
      if (bytes.length + chunk.length > 16384) {
        throw const FormatException('body_limit');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      req.response.headers.set('Cache-Control', 'no-store');
      req.response.headers.set('X-Content-Type-Options', 'nosniff');
      req.response.headers.set('Referrer-Policy', 'no-referrer');
      req.response.headers.set(
        'Content-Security-Policy',
        "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws://127.0.0.1:${server.port}; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
      );
      req.response.headers.set(
        'Permissions-Policy',
        'camera=(), microphone=(self)',
      );
      if (req.headers.value('host') != '127.0.0.1:${server.port}') {
        await _json(req, {'error': 'invalid_host'}, 403);
        return;
      }
      final path = req.uri.path;
      if (path == '/ws') {
        if (req.headers.value('origin') != origin ||
            req.uri.queryParameters['token'] != token ||
            _browser != null) {
          await _json(req, {'error': 'browser_not_allowed_or_busy'}, 403);
          return;
        }
        final socket = await WebSocketTransformer.upgrade(req);
        _browser = socket;
        _paused = false;
        _lastHeartbeat = DateTime.now();
        socket.listen(
          (message) {
            if (!identical(_browser, socket)) return;
            if (message is List<int>) {
              if (!_paused) probe.appendAudio(message);
            } else if (message == 'heartbeat') {
              _lastHeartbeat = DateTime.now();
            } else if (message == 'interrupt') {
              probe.interrupt(clearInput: true);
            } else if (message == 'pause') {
              _paused = true;
              probe.pause();
            } else if (message == 'capture_started') {
              _paused = false;
              _lastHeartbeat = DateTime.now();
              probe.record('capture_started');
              probe.status = '已连接 · 麦克风采集中';
              emit(probe.state);
            }
          },
          onDone: () {
            if (identical(_browser, socket)) {
              _browser = null;
              unawaited(
                probe.close(
                  message: '页面连接已关闭 · 可重新连接',
                  reason: 'browser_closed',
                ),
              );
            }
          },
          onError: (Object _) {
            if (identical(_browser, socket)) {
              _browser = null;
              unawaited(
                probe.close(message: '页面连接异常', reason: 'browser_error'),
              );
            }
          },
        );
        emit(probe.state);
        return;
      }
      if (req.method == 'POST') {
        if (req.headers.value('origin') != origin ||
            req.headers.value('x-probe-token') != token) {
          await _json(req, {'error': 'request_not_allowed'}, 403);
          return;
        }
        if (path == '/connect') {
          if (_browser == null) {
            await _json(req, {'error': '请刷新页面后重试'}, 409);
            return;
          }
          final body = await _body(req);
          final key = (body['key'] as String? ?? '').trim();
          final host = (body['host'] as String? ?? '').trim();
          final style = body['style'] as String? ?? 'playful';
          if (key.isEmpty && _config == null) {
            await _json(req, {'error': '本机临时配置已清除或过期，请填写密钥'}, 400);
            return;
          }
          if (key.isEmpty &&
              host.isNotEmpty &&
              host.replaceFirst('https://', '') != _config!.uri.host) {
            await _json(req, {'error': '更换业务空间需要重新填写密钥'}, 400);
            return;
          }
          final config = key.isEmpty
              ? ProbeConfig(_config!.uri.host, _config!.key, style: style)
              : ProbeConfig(host, key, style: style);
          // The only upstream request carrying the supplied key is Qwen WSS.
          body.clear();
          await probe.start(config);
          if (probe.ready) {
            _config = config;
            _paused = false;
            _credentialExpiry?.cancel();
            _credentialExpiry = Timer(credentialLifetime, () {
              forgetCredentials();
              emit(probe.state);
            });
          }
          emit(probe.state);
          await _json(req, {
            'ok': probe.ready,
            'credentials_ready': hasCredentials,
          });
          return;
        }
        if (path == '/grant') {
          await _json(req, probe.grant());
          return;
        }
        if (path == '/stop') {
          probe.stopOutput();
          await _json(req, {'ok': true});
          return;
        }
        if (path == '/disconnect') {
          final body = await _body(req);
          final suppliedReason = body['reason'];
          final reason =
              [
                'user_disconnect',
                'audio_backpressure',
                'capture_ended',
                'playback_error',
              ].contains(suppliedReason)
              ? suppliedReason as String
              : 'user_disconnect';
          final message = {
            'user_disconnect': '已断开语音 · 本机临时配置保留，可直接重连',
            'audio_backpressure': '上传积压，语音已断开 · 可直接重连',
            'capture_ended': '麦克风设备中断，语音已断开 · 可直接重连',
            'playback_error': '音频播放异常，语音已断开 · 可直接重连',
          }[reason]!;
          await probe.close(message: message, reason: reason);
          await _json(req, {'ok': true});
          return;
        }
        if (path == '/forget') {
          forgetCredentials();
          await probe.close(
            message: '已结束并清除本机临时密钥',
            reason: 'credentials_cleared',
          );
          await _json(req, {'ok': true});
          return;
        }
        if (path == '/report') {
          final report = probe.report();
          await saveReport();
          await _json(req, {'ok': true, 'report': report});
          return;
        }
        await _json(req, {'error': 'not_found'}, 404);
        return;
      }
      if (req.method != 'GET') {
        await _json(req, {'error': 'method'}, 405);
        return;
      }
      if (path == '/bootstrap') {
        // Same-origin only: no CORS, no JSONP, no credentials returned.
        if (req.headers.value('sec-fetch-site') == 'cross-site') {
          await _json(req, {'error': 'request_not_allowed'}, 403);
          return;
        }
        await _json(req, {
          'token': token,
          'model': ProbeConfig.model,
          'credentials_ready': hasCredentials,
        });
        return;
      }
      const files = {
        '/': 'index.html',
        '/probe.js': 'probe.js',
        '/pcm-worklet.js': 'pcm-worklet.js',
        '/style.css': 'style.css',
      };
      final name = files[path];
      if (name == null) {
        await _json(req, {'error': 'not_found'}, 404);
        return;
      }
      final file = File('${assets.path}${Platform.pathSeparator}$name');
      req.response.headers.contentType = ContentType.parse(
        name.endsWith('.js')
            ? 'text/javascript; charset=utf-8'
            : name.endsWith('.css')
            ? 'text/css; charset=utf-8'
            : 'text/html; charset=utf-8',
      );
      await req.response.addStream(file.openRead());
      await req.response.close();
    } catch (_) {
      // Never print exception details, URLs, request bodies or headers.
      try {
        await _json(req, {'error': '操作失败，请检查配置或连接状态；密钥不会写入日志'}, 400);
      } catch (_) {}
    }
  }

  Future<void> close() async {
    _ticker?.cancel();
    forgetCredentials();
    await probe.close();
    final browser = _browser;
    _browser = null;
    await browser?.close();
    await server.close(force: true);
    await _reportWrites.catchError((Object _) {});
  }
}
