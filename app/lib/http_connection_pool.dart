import 'dart:async';
import 'dart:io';

/// Exclusive clients: cancelling one request never closes another request's
/// socket. Only fully consumed successful responses return to the idle pool.
class HttpConnectionPool {
  HttpConnectionPool({this.idleTime = const Duration(seconds: 10)});
  final Duration idleTime;
  final _idle = <_IdleClient>[];
  int _generation = 0;

  HttpClientLease acquire(String key, HttpClient Function() create) {
    final index = _idle.indexWhere((item) => item.key == key);
    if (index >= 0) {
      final item = _idle.removeAt(index);
      item.timer.cancel();
      return HttpClientLease._(this, key, item.client, _generation, true);
    }
    return HttpClientLease._(this, key, create(), _generation, false);
  }

  /// Network changes discard idle connections. In-flight requests own their
  /// clients until completion/cancellation; old clients cannot re-enter pool.
  void invalidate() {
    _generation++;
    for (final item in _idle) {
      item.timer.cancel();
      item.client.close(force: true);
    }
    _idle.clear();
  }

  void _release(HttpClientLease lease, bool reusable) {
    if (!reusable || lease.generation != _generation || _idle.length >= 4) {
      lease.client.close(force: true);
      return;
    }
    late final _IdleClient item;
    item = _IdleClient(
      lease.key,
      lease.client,
      Timer(idleTime, () {
        _idle.remove(item);
        item.client.close(force: true);
      }),
    );
    _idle.add(item);
  }
}

class HttpClientLease {
  HttpClientLease._(
    this.pool,
    this.key,
    this.client,
    this.generation,
    this.reused,
  );
  final HttpConnectionPool pool;
  final String key;
  final HttpClient client;
  final int generation;
  final bool reused;
  bool _released = false;
  // HttpClient returns the drained socket to its internal pool on the next
  // event-loop turn. Waiting here avoids opening a second socket immediately.
  Future<void> get ready =>
      reused ? Future<void>.delayed(Duration.zero) : Future<void>.value();
  void release({bool reusable = false}) {
    if (_released) return;
    _released = true;
    pool._release(this, reusable);
  }
}

class _IdleClient {
  _IdleClient(this.key, this.client, this.timer);
  final String key;
  final HttpClient client;
  final Timer timer;
}
