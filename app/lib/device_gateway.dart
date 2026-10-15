import 'dart:async';
import 'dart:convert';
import 'dart:io';

class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.name,
    required this.kind,
    required this.channels,
    this.details = const {},
  });
  final String id, name, kind;
  final int channels;
  final Map<String, dynamic> details;

  bool get connectedCoyote =>
      kind == 'COYOTE_030' &&
      details['slotState']?['hasDevice'] == true &&
      details['props']?['connectState'] != 'disconnected';
}

/// Device discovery. Output is exposed only by explicitly supported adapters.
abstract class DeviceGateway {
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  final Map<String, RemoteDevice> deviceMap = {};
  List<RemoteDevice> get devices => List.unmodifiable(deviceMap.values);
  String status = '未连接';
  Uri? pairingUri;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  Timer? _heartbeat;
  bool _closed = false, _used = false;
  bool get isClosed => _closed;
  Future<void> connect(Uri endpoint);
  Future<void> refresh();
  void _changed() {
    if (!_closed && !_changes.isClosed) _changes.add(null);
  }

  static void validateEndpoint(Uri uri) {
    if (!['ws', 'wss'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme == 'ws' &&
            !['127.0.0.1', 'localhost', '::1'].contains(uri.host))) {
      throw ArgumentError('使用 wss 地址；ws 仅允许本机。地址不能包含凭据或配对参数。');
    }
  }

  Future<void> _open(Uri endpoint, void Function(dynamic) onMessage) async {
    validateEndpoint(endpoint);
    if (_used || _closed) throw StateError('请新建连接');
    _used = true;
    status = '连接中';
    _changed();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    client.findProxy = (_) => 'DIRECT';
    try {
      final pending = WebSocket.connect(
        endpoint.toString(),
        customClient: client,
        compression: CompressionOptions.compressionOff,
      );
      // A timed-out handshake must not leave a late live socket behind.
      pending.then((ws) {
        if (_closed) ws.close();
      }, onError: (_) {});
      final ws = await pending.timeout(const Duration(seconds: 8));
      if (_closed) {
        await ws.close();
        throw StateError('连接已取消');
      }
      _socket = ws;
      _sub = ws.listen(
        (raw) {
          try {
            if (raw is! String || raw.length > 65536) {
              throw const FormatException('设备消息过大或格式错误');
            }
            onMessage(jsonDecode(raw));
          } catch (_) {
            _fail('协议数据无效，连接已关闭');
          }
        },
        onError: (_) => _fail('连接错误'),
        onDone: () => _fail('连接已断开'),
      );
    } catch (_) {
      _fail('连接失败');
      rethrow;
    } finally {
      client.close();
    }
  }

  void _send(Object frame) {
    if (_closed || _socket == null) throw StateError('未连接');
    _socket!.add(jsonEncode(frame));
  }

  void _fail(String message) {
    if (_closed) return;
    status = message;
    deviceMap.clear();
    pairingUri = null;
    _changed();
    unawaited(close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _heartbeat?.cancel();
    _cancelPending();
    await _sub?.cancel();
    await _socket?.close().timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
    deviceMap.clear();
    pairingUri = null;
    if (!_changes.isClosed) await _changes.close();
  }

  void _cancelPending();
}

class IntifaceGateway extends DeviceGateway {
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _next = 0;
  int _revision = 0;
  bool _scanning = false;
  @override
  Future<void> connect(Uri endpoint) async {
    try {
      await _open(endpoint, _handle);
      final info = await _request('RequestServerInfo', {
        'ClientName': 'AI Haptics capability inspector',
        'MessageVersion': 3,
      });
      final body = info['ServerInfo'];
      if (body is! Map || body['MessageVersion'] != 3) {
        throw const FormatException('需要兼容 Buttplug v3 的服务');
      }
      final ping = (body['MaxPingTime'] as num? ?? 0).toInt();
      if (ping > 0) {
        _heartbeat = Timer.periodic(
          Duration(milliseconds: (ping ~/ 2).clamp(100, 10000)),
          (_) {
            if (_pending.length < 4) {
              unawaited(
                _request('Ping', {}).catchError((Object e) {
                  _fail('服务心跳超时');
                  return <String, dynamic>{};
                }),
              );
            }
          },
        );
      }
      await refresh();
      status = '已连接 Intiface · 只读设备信息';
      _changed();
    } catch (_) {
      _fail('连接未完成，请检查服务');
      await close();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> data,
  ) async {
    if (_pending.length >= 16) throw StateError('请求过多');
    final id = ++_next, result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    try {
      _send([
        {
          method: {'Id': id, ...data},
        },
      ]);
      final response = await result.future.timeout(const Duration(seconds: 5));
      if (response.containsKey('Error')) throw StateError('服务拒绝请求');
      return response;
    } finally {
      _pending.remove(id);
    }
  }

  RemoteDevice _device(Map data) {
    final index = data['DeviceIndex'], name = data['DeviceName'];
    if (index is! int || name is! String || name.length > 200) {
      throw const FormatException('设备描述无效');
    }
    final scalars = (data['DeviceMessages']?['ScalarCmd'] as List? ?? []);
    final vibrate = scalars
        .where((s) => s is Map && s['ActuatorType'] == 'Vibrate')
        .length;
    return RemoteDevice(
      id: 'intiface:$index',
      name: name,
      kind: vibrate > 0 ? 'vibration' : 'unsupported',
      channels: vibrate,
      details: {'device_index': index, 'capabilities': data['DeviceMessages']},
    );
  }

  void _handle(dynamic raw) {
    if (raw is! List || raw.length > 128) throw const FormatException('无效消息数组');
    for (final item in raw) {
      if (item is! Map || item.length != 1) throw const FormatException('无效消息');
      final body = item.values.first;
      if (body is! Map) throw const FormatException('无效消息体');
      final id = body['Id'];
      if (_pending[id] case final pending? when !pending.isCompleted) {
        pending.complete(Map<String, dynamic>.from(item));
      }
      if (item.containsKey('DeviceAdded')) {
        final d = _device(body);
        if (!deviceMap.containsKey(d.id) && deviceMap.length >= 64) {
          throw const FormatException('设备数超过限制');
        }
        deviceMap[d.id] = d;
        _revision++;
        _changed();
      }
      if (item.containsKey('DeviceRemoved')) {
        deviceMap.remove('intiface:${body['DeviceIndex']}');
        _revision++;
        _changed();
      }
    }
  }

  @override
  Future<void> refresh() async {
    final revision = _revision;
    final reply = await _request('RequestDeviceList', {});
    final list = reply['DeviceList']?['Devices'];
    if (list is! List || list.length > 64) {
      throw const FormatException('设备列表无效');
    }
    final next = <String, RemoteDevice>{};
    for (final item in list) {
      final d = _device(item as Map);
      next[d.id] = d;
    }
    if (_closed || revision != _revision) return;
    deviceMap
      ..clear()
      ..addAll(next);
    _revision++;
    _changed();
  }

  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    try {
      await _request('StartScanning', {});
      status = '扫描中（5 秒）';
      _changed();
      await Future<void>.delayed(const Duration(seconds: 5));
      if (!_closed) {
        await _request('StopScanning', {});
        await refresh();
        status = '扫描完成 · 只读设备信息';
        _changed();
      }
    } finally {
      _scanning = false;
    }
  }

  @override
  void _cancelPending() {
    for (final p in _pending.values) {
      if (!p.isCompleted) p.completeError(StateError('连接已关闭'));
    }
    _pending.clear();
  }
}

class DglabV4Gateway extends DeviceGateway {
  DglabV4Gateway() {
    // Closing an unused instance must not produce an unhandled future error.
    unawaited(_hello.future.catchError((Object _) {}));
  }
  final _hello = Completer<void>();
  final _clients = <String>{};
  int get pairedAppCount => _clients.length;
  void _updateDeviceStatus() {
    if (_clients.isEmpty) return;
    final connected = devices.where((d) => d.connectedCoyote).length;
    status = connected == 0
        ? 'APP 已配对 · 尚无已连接的郊狼 3.0，请在 DG-LAB 中连接蓝牙设备'
        : 'APP 已配对 · 已发现 $connected 台郊狼 3.0，尚需选择并授权';
  }

  final _revisions = <String, int>{};
  int _revisionClock = 0;
  void _touch(String client) => _revisions[client] = ++_revisionClock;
  final _pending =
      <String, ({String client, Completer<Map<String, dynamic>> result})>{};
  int _next = 0;
  Uri? _endpoint;
  Future<Map<String, dynamic>> operate(
    RemoteDevice device,
    Map<String, dynamic> operation, {
    bool clear = false,
  }) async {
    final current = deviceMap[device.id];
    if (current == null || current.kind != 'COYOTE_030' || _closed) {
      throw StateError('郊狼 3.0 不可用');
    }
    final client = current.details['client_id'] as String,
        slot = current.details['slot_id'] as String;
    if (_pending.length >= (clear || operation['t'] == 7 ? 48 : 24)) {
      throw StateError('设备响应过慢');
    }
    final id = 'output-${++_next}', result = Completer<Map<String, dynamic>>();
    _pending[id] = (client: client, result: result);
    try {
      _send({
        'type': 'message',
        'clientId': client,
        'data': {
          't': 'req',
          'reqId': id,
          'm': clear ? 'device.op.clear' : 'device.op',
          'data': {'s': slot, ...operation},
        },
      });
      final reply = await result.future.timeout(const Duration(seconds: 2));
      if (reply.containsKey('error')) throw StateError('APP 拒绝设备操作');
      final body = reply['result'];
      if (body is! Map) throw StateError('设备回执无效');
      if (!clear &&
          (body['type'] != operation['t'] ||
              !['completed', 'replaced', 'cleared'].contains(body['reason']) ||
              body['slotId'] != null && body['slotId'] != slot ||
              body['channel'] != null && body['channel'] != operation['c'])) {
        throw StateError('设备回执不匹配');
      }
      return Map<String, dynamic>.from(body);
    } finally {
      _pending.remove(id);
    }
  }

  @override
  Future<void> connect(Uri endpoint) async {
    _endpoint = endpoint;
    try {
      // Attach an error handler before network setup can fail.
      final ready = _hello.future.timeout(const Duration(seconds: 8));
      unawaited(ready.catchError((Object _) {}));
      await _open(endpoint, _handle);
      await ready;
    } catch (_) {
      _fail('连接未完成，请检查服务');
      await close();
      rethrow;
    }
  }

  String _boundedId(dynamic value) {
    if (value is! String || value.isEmpty || value.length > 160) {
      throw const FormatException('无效连接标识');
    }
    return value;
  }

  String _key(String client, String slot) => jsonEncode([client, slot]);
  RemoteDevice _device(String client, Map raw) {
    final slot = _boundedId(raw['slotId']),
        name = raw['name'],
        type = raw['type'];
    if (name is! String ||
        name.length > 200 ||
        type is! String ||
        type.length > 80) {
      throw const FormatException('设备描述无效');
    }
    return RemoteDevice(
      id: _key(client, slot),
      name: name,
      kind: type,
      channels: type == 'COYOTE_030' ? 2 : 0,
      details: {
        'client_id': client,
        'slot_id': slot,
        'props': _state(raw['props']),
        'slotState': _state(raw['slotState']),
      },
    );
  }

  void _replace(String client, dynamic list) {
    if (list is! List || list.length > 64) {
      throw const FormatException('设备列表无效');
    }
    final next = <String, RemoteDevice>{};
    for (final item in list) {
      final d = _device(client, item as Map);
      next[d.id] = d;
    }
    final others = deviceMap.values
        .where((d) => d.details['client_id'] != client)
        .length;
    if (others + next.length > 128) throw const FormatException('设备过多');
    deviceMap.removeWhere((_, d) => d.details['client_id'] == client);
    deviceMap.addAll(next);
    _touch(client);
    _updateDeviceStatus();
    _changed();
  }

  void _handle(dynamic frame) {
    if (frame is! Map) throw const FormatException('无效服务器消息');
    switch (frame['type']) {
      case 'hello':
        if (_hello.isCompleted) throw const FormatException('重复 hello');
        final target = _boundedId(frame['clientId']);
        final appUrl = _endpoint!.replace(queryParameters: {'tid': target});
        pairingUri = Uri.https('dungeon-lab.cn', '/s/', {
          'v': '1',
          'action': 'socket',
          'url': appUrl.toString(),
        });
        status = '等待 DG-LAB 4 APP 配对';
        _hello.complete();
        _changed();
      case 'client_attached':
        final client = _boundedId(frame['clientId']);
        if (!_hello.isCompleted || _clients.length >= 8) {
          throw const FormatException('配对状态无效');
        }
        _clients.add(client);
        _touch(client);
        status = 'APP 已配对 · 只读设备信息';
        _changed();
      case 'client_disconnected':
        final client = _boundedId(frame['clientId']);
        _clients.remove(client);
        _revisions.remove(client);
        for (final p in _pending.values.where((p) => p.client == client)) {
          if (!p.result.isCompleted) {
            p.result.completeError(StateError('APP 已断开'));
          }
        }
        deviceMap.removeWhere((_, d) => d.details['client_id'] == client);
        if (_clients.isEmpty) status = '等待 DG-LAB 4 APP 重新配对';
        _updateDeviceStatus();
        _changed();
      case 'heartbeat':
        _send({'type': 'ping'});
      case 'message':
        final client = _boundedId(frame['clientId']);
        if (!_clients.contains(client)) {
          throw const FormatException('未知 APP 来源');
        }
        final data = frame['data'];
        if (data is! Map) throw const FormatException('无效 APP 消息');
        if (data['t'] == 'resp') {
          final pending = _pending[data['reqId']];
          if (pending != null &&
              pending.client == client &&
              !pending.result.isCompleted) {
            pending.result.complete(Map<String, dynamic>.from(data));
          }
        }
        if (data['t'] == 'ev') {
          if (data['ev'] == 'devices.snapshot') {
            _replace(client, data['devices']);
          }
          if (data['ev'] == 'devices.patch') {
            final removed = data['removed'] as List? ?? [],
                added = data['added'] as List? ?? [];
            if (removed.length > 64 || added.length > 64) {
              throw const FormatException('设备列表过大');
            }
            for (final slot in removed) {
              deviceMap.remove(_key(client, _boundedId(slot)));
            }
            for (final item in added) {
              final d = _device(client, item as Map);
              deviceMap[d.id] = d;
            }
            if (deviceMap.length > 128) throw const FormatException('设备过多');
            _touch(client);
            _updateDeviceStatus();
            _changed();
          }
          if (data['ev'] == 'slots.patch') {
            final slots = data['slots'];
            if (slots is! List || slots.length > 64) {
              throw const FormatException('状态更新无效');
            }
            for (final item in slots) {
              final key = _key(client, _boundedId(item['slotId'])),
                  old = deviceMap[key];
              if (old == null) continue;
              deviceMap[key] = RemoteDevice(
                id: old.id,
                name: old.name,
                kind: old.kind,
                channels: old.channels,
                details: {
                  ...old.details,
                  'props': _merge(old.details['props'], item['props']),
                  'slotState': _merge(
                    old.details['slotState'],
                    item['slotState'],
                  ),
                },
              );
            }
            _touch(client);
            _updateDeviceStatus();
            _changed();
          }
        }
      case 'error':
        _fail('中继服务拒绝连接');
      case 'idle_timeout':
        _fail('中继连接已超时');
    }
  }

  Map<String, dynamic> _state(dynamic raw) {
    if (raw == null) return {};
    if (raw is! Map) throw const FormatException('状态必须是对象');
    var nodes = 0;
    void check(dynamic value, int depth) {
      if (++nodes > 1024 || depth > 8) throw const FormatException('状态数据过大');
      if (value is Map) {
        if (value.length > 128) throw const FormatException('状态字段过多');
        for (final entry in value.entries) {
          if (entry.key is! String || (entry.key as String).length > 128) {
            throw const FormatException('状态字段无效');
          }
          check(entry.value, depth + 1);
        }
      } else if (value is List) {
        if (value.length > 128) throw const FormatException('状态列表过长');
        for (final item in value) {
          check(item, depth + 1);
        }
      } else if (value is String && value.length > 4096) {
        throw const FormatException('状态文本过长');
      }
    }

    check(raw, 0);
    if (utf8.encode(jsonEncode(raw)).length > 32768) {
      throw const FormatException('状态缓存过大');
    }
    return Map<String, dynamic>.from(raw);
  }

  Map<String, dynamic> _merge(dynamic old, dynamic patch, [int depth = 0]) {
    if (depth > 8) throw const FormatException('状态嵌套过深');
    final result = Map<String, dynamic>.from(old as Map? ?? {});
    if (patch == null) return result;
    if (patch is! Map || patch.length > 128) {
      throw const FormatException('状态数据无效');
    }
    for (final entry in patch.entries) {
      if (entry.key is! String) throw const FormatException('状态字段无效');
      result[entry.key] = entry.value is Map
          ? _merge(
              result[entry.key] is Map ? result[entry.key] : {},
              entry.value,
              depth + 1,
            )
          : entry.value;
    }
    return depth == 0 ? _state(result) : result;
  }

  @override
  Future<void> refresh() async {
    for (final client in _clients.toList()) {
      if (_pending.length >= 16) throw StateError('请求过多');
      final revision = _revisions[client];
      final id = 'inspect-${++_next}',
          result = Completer<Map<String, dynamic>>();
      _pending[id] = (client: client, result: result);
      try {
        _send({
          'type': 'message',
          'clientId': client,
          'data': {'t': 'req', 'reqId': id, 'm': 'devices.get'},
        });
        final reply = await result.future.timeout(const Duration(seconds: 5));
        if (reply.containsKey('error')) throw StateError('APP 拒绝读取设备列表');
        if (!_closed &&
            _clients.contains(client) &&
            _revisions[client] == revision) {
          _replace(client, reply['result']?['devices']);
        }
      } finally {
        _pending.remove(id);
      }
    }
  }

  @override
  void _cancelPending() {
    if (!_hello.isCompleted) _hello.completeError(StateError('连接已关闭'));
    for (final p in _pending.values) {
      if (!p.result.isCompleted) p.result.completeError(StateError('连接已关闭'));
    }
    _pending.clear();
    _clients.clear();
    _revisions.clear();
  }
}
