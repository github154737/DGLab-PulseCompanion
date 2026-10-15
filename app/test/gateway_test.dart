import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/device_gateway.dart';

class Relay {
  Relay(this.server);
  final HttpServer server;
  final ready = Completer<WebSocket>();
  final received = <dynamic>[];
  WebSocket? socket;
  static Future<Relay> start(void Function(Relay, dynamic) respond) async {
    final r = Relay(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    r.server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      r.socket = ws;
      ws.listen((raw) {
        final data = jsonDecode(raw as String);
        r.received.add(data);
        respond(r, data);
      });
      r.ready.complete(ws);
    });
    return r;
  }

  Uri get uri => Uri.parse('ws://127.0.0.1:${server.port}/v4');
  void send(Object data) => socket!.add(jsonEncode(data));
  Future<void> close() async {
    await socket?.close();
    await server.close(force: true);
  }
}

Future<void> until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(end)) throw StateError('condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Map<String, dynamic> coyote(String slot) => {
  'slotId': slot,
  'name': 'Coyote 3',
  'type': 'COYOTE_030',
  'props': {'power': 80},
  'slotState': {
    'hasDevice': true,
    'channelA': {'isMuted': false, 'intensity': 0},
  },
};
void appEvent(Relay r, Map<String, dynamic> data, [String client = 'phone']) {
  r.send({'type': 'message', 'clientId': client, 'data': data});
}

void main() {
  test(
    'endpoints reject credentials, pairing parameters and nonlocal cleartext',
    () {
      for (final url in [
        'ws://192.168.1.2:12345',
        'wss://user:pass@host/',
        'wss://host/?tid=x',
        'https://host',
        'wss://host/#x',
      ]) {
        expect(
          () => DeviceGateway.validateEndpoint(Uri.parse(url)),
          throwsArgumentError,
        );
      }
      DeviceGateway.validateEndpoint(Uri.parse('wss://example.com/v4'));
      DeviceGateway.validateEndpoint(Uri.parse('ws://127.0.0.1:12345'));
    },
  );
  test(
    'Intiface handshake, actuator typing, refresh and removal emit no outputs',
    () async {
      final r = await Relay.start((r, frame) {
        final command = (frame as List).single as Map;
        final name = command.keys.single;
        final id = command.values.single['Id'];
        if (name == 'RequestServerInfo') {
          r.send([
            {
              'ServerInfo': {'Id': id, 'MessageVersion': 3, 'MaxPingTime': 0},
            },
          ]);
        } else if (name == 'RequestDeviceList') {
          r.send([
            {
              'DeviceList': {
                'Id': id,
                'Devices': [
                  {
                    'DeviceIndex': 4,
                    'DeviceName': 'Mixed actuators',
                    'DeviceMessages': {
                      'ScalarCmd': [
                        {'ActuatorType': 'Vibrate'},
                        {'ActuatorType': 'Oscillate'},
                      ],
                    },
                  },
                  {
                    'DeviceIndex': 5,
                    'DeviceName': 'Linear only',
                    'DeviceMessages': {
                      'LinearCmd': [{}],
                    },
                  },
                ],
              },
            },
          ]);
        }
      });
      final gateway = IntifaceGateway();
      addTearDown(() async {
        await gateway.close();
        await r.close();
      });
      await gateway.connect(r.uri);
      expect(gateway.devices.first.channels, 1);
      expect(gateway.devices.last.kind, 'unsupported');
      r.send([
        {
          'DeviceRemoved': {'Id': 0, 'DeviceIndex': 4},
        },
      ]);
      await until(() => gateway.devices.length == 1);
      await gateway.refresh();
      expect(gateway.devices.length, 2);
      expect(r.received.map((f) => (f as List).single.keys.single).toSet(), {
        'RequestServerInfo',
        'RequestDeviceList',
      });
      await r.socket!.close();
      await until(() => gateway.devices.isEmpty);
    },
  );
  test('DGLAB pairs, merges patches, correlates read replies and clears disconnected data', () async {
    final r = await Relay.start((r, frame) {
      if (frame['type'] == 'message') {
        final req = frame['data'];
        appEvent(r, {
          't': 'resp',
          'reqId': req['reqId'],
          'result': {
            'devices': [coyote('a')],
          },
        });
      }
    });
    final g = DglabV4Gateway();
    addTearDown(() async {
      await g.close();
      await r.close();
    });
    final pending = g.connect(r.uri);
    await r.ready.future;
    r.send({'type': 'hello', 'clientId': 'controller'});
    await pending;
    final nested = Uri.parse(g.pairingUri!.queryParameters['url']!);
    expect(nested.queryParameters['tid'], 'controller');
    r.send({'type': 'client_attached', 'clientId': 'phone'});
    appEvent(r, {
      't': 'ev',
      'ev': 'devices.snapshot',
      'devices': [coyote('a')],
    });
    await until(() => g.devices.length == 1);
    expect(g.devices.single.channels, 2);
    appEvent(r, {
      't': 'ev',
      'ev': 'slots.patch',
      'slots': [
        {
          'slotId': 'a',
          'props': {'power': 79},
          'slotState': {
            'channelA': {'isMuted': true},
          },
        },
      ],
    });
    await until(() => g.devices.single.details['props']['power'] == 79);
    expect(g.devices.single.details['slotState']['channelA'], {
      'isMuted': true,
      'intensity': 0,
    });
    appEvent(r, {
      't': 'ev',
      'ev': 'devices.patch',
      'removed': ['a'],
      'added': [coyote('b')],
    });
    await until(() => g.devices.single.details['slot_id'] == 'b');
    await g.refresh();
    expect(g.devices.single.details['slot_id'], 'a');
    r.send({'type': 'heartbeat'});
    await until(() => r.received.any((m) => m['type'] == 'ping'));
    expect(
      r.received
          .where((m) => m['type'] == 'message')
          .every((m) => m['data']['m'] == 'devices.get'),
      true,
    );
    r.send({'type': 'client_disconnected', 'clientId': 'phone'});
    await until(() => g.devices.isEmpty);
    expect(g.status, contains('重新配对'));
    await r.socket!.close();
    await until(() => g.pairingUri == null);
  });
  test('DGLAB ignores response from another paired APP, disconnect cancels pending read', () async {
    final request = Completer<Map<String, dynamic>>();
    final r = await Relay.start((r, frame) {
      if (frame['type'] == 'message' && !request.isCompleted) {
        request.complete(Map.from(frame));
      }
    });
    final g = DglabV4Gateway();
    addTearDown(() async {
      await g.close();
      await r.close();
    });
    final connecting = g.connect(r.uri);
    await r.ready.future;
    r.send({'type': 'hello', 'clientId': 'controller'});
    await connecting;
    for (final id in ['phone', 'other']) {
      r.send({'type': 'client_attached', 'clientId': id});
    }
    appEvent(r, {
      't': 'ev',
      'ev': 'devices.snapshot',
      'devices': [coyote('a')],
    });
    await until(() => g.devices.isNotEmpty);
    var completed = false;
    final reading = g.refresh().then((_) {
      completed = true;
    });
    final assertion = expectLater(reading, throwsStateError);
    final req = await request.future;
    appEvent(r, {
      't': 'resp',
      'reqId': req['data']['reqId'],
      'result': {'devices': []},
    }, 'other');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(completed, false);
    expect(g.devices.length, 1);
    r.send({'type': 'client_disconnected', 'clientId': 'phone'});
    await assertion;
    expect(g.devices, isEmpty);
  });
  test('malformed remote frame closes connection and clears pairing', () async {
    final r = await Relay.start((_, _) {});
    final g = DglabV4Gateway();
    addTearDown(() async {
      await g.close();
      await r.close();
    });
    final connecting = g.connect(r.uri);
    await r.ready.future;
    r.send({'type': 'hello', 'clientId': 'controller'});
    await connecting;
    r.socket!.add('x' * 65537);
    await until(() => g.pairingUri == null);
    expect(g.status, contains('协议数据无效'));
  });
  test('closing an unused gateway is harmless', () async {
    await DglabV4Gateway().close();
    await IntifaceGateway().close();
  });
}
