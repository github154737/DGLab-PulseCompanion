import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Ephemeral loopback-only source for Android's progressive MP3 decoder.
/// The random URL grants access only to this one clip; no API credentials cross
/// into the player. Retaining bounded chunks allows decoder reconnects.
class ProgressiveAudio {
  ProgressiveAudio._(this._server, this._path) {
    _server.listen(_serve);
  }
  final HttpServer _server;
  final String _path;
  final _chunks = <Uint8List>[];
  Completer<void> _changed = Completer<void>();
  bool _ended = false, _closed = false;
  int _bytes = 0, _readers = 0;
  static const limit = 16 * 1024 * 1024;
  static Future<ProgressiveAudio> open() async {
    final random = Random.secure();
    final token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return ProgressiveAudio._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      '/speech/$token.mp3',
    );
  }

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}$_path');
  void _wake() {
    final old = _changed;
    _changed = Completer<void>();
    old.complete();
  }

  void add(Uint8List bytes) {
    if (_closed || _ended) throw StateError('stream_closed');
    if (_bytes + bytes.length > limit) throw StateError('audio_too_large');
    _bytes += bytes.length;
    _chunks.add(Uint8List.fromList(bytes));
    _wake();
  }

  void finish() {
    if (_closed || _ended) return;
    _ended = true;
    _wake();
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    var admitted = false;
    try {
      response.persistentConnection = false;
      if (_closed ||
          request.uri.path != _path ||
          request.uri.hasQuery ||
          !['GET', 'HEAD'].contains(request.method) ||
          _readers >= 3) {
        response.statusCode = 404;
        return;
      }
      _readers++;
      admitted = true;
      // Before EOF there is no seekable total length. Ignore Range and answer
      // 200 from byte zero, as permitted by HTTP; never expose a fake length.
      response.headers.contentType = ContentType('audio', 'mpeg');
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('Accept-Ranges', 'none');
      response.bufferOutput = false;
      if (_ended) response.contentLength = _bytes;
      if (request.method == 'HEAD') return;
      var index = 0;
      while (!_closed) {
        while (index < _chunks.length && !_closed) {
          response.add(_chunks[index++]);
          await response.flush().timeout(const Duration(seconds: 10));
        }
        if (_ended || _closed) break;
        await _changed.future.timeout(const Duration(seconds: 65));
      }
    } catch (_) {
      // Player cancellation/disconnect is expected; never leak private URLs.
    } finally {
      if (admitted) _readers--;
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _wake();
    await _server.close(force: true);
    _chunks.clear();
  }
}
