import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/device_gateway.dart';

import 'gateway_test.dart' show Relay, until, coyote, appEvent;

void main() {
  test(
    'DGLAB over-capacity refresh preserves the previous complete list',
    () async {
      final r = await Relay.start((r, frame) {
        if (frame['type'] != 'message') return;
        final client = frame['clientId'] as String;
        final count = client == 'a'
            ? 64
            : client == 'b'
            ? 63
            : 2;
        appEvent(r, {
          't': 'resp',
          'reqId': frame['data']['reqId'],
          'result': {'devices': List.generate(count, (i) => coyote('$i'))},
        }, client);
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
      for (final client in ['a', 'b', 'c']) {
        r.send({'type': 'client_attached', 'clientId': client});
        final count = client == 'a'
            ? 64
            : client == 'b'
            ? 63
            : 1;
        appEvent(r, {
          't': 'ev',
          'ev': 'devices.snapshot',
          'devices': List.generate(count, (i) => coyote('$i')),
        }, client);
      }
      await until(() => g.devices.any((d) => d.details['client_id'] == 'c'));
      expect(g.devices.length, 128);
      await expectLater(g.refresh(), throwsFormatException);
      expect(g.devices.length, 128);
      expect(g.devices.where((d) => d.details['client_id'] == 'c').length, 1);
    },
  );
  test('Intiface late refresh cannot resurrect a removed device', () async {
    final requested = Completer<int>();
    var reads = 0;
    final device = {
      'DeviceIndex': 4,
      'DeviceName': 'A',
      'DeviceMessages': <String, dynamic>{},
    };
    final r = await Relay.start((r, frame) {
      final cmd = (frame as List).single as Map;
      final id = cmd.values.single['Id'] as int;
      if (cmd.containsKey('RequestServerInfo')) {
        r.send([
          {
            'ServerInfo': {'Id': id, 'MessageVersion': 3, 'MaxPingTime': 0},
          },
        ]);
      } else if (cmd.containsKey('RequestDeviceList')) {
        if (++reads == 1) {
          r.send([
            {
              'DeviceList': {
                'Id': id,
                'Devices': [device],
              },
            },
          ]);
        } else {
          requested.complete(id);
        }
      }
    });
    final g = IntifaceGateway();
    addTearDown(() async {
      await g.close();
      await r.close();
    });
    await g.connect(r.uri);
    final reading = g.refresh(), id = await requested.future;
    r.send([
      {
        'DeviceRemoved': {'Id': 0, 'DeviceIndex': 4},
      },
    ]);
    await until(() => g.devices.isEmpty);
    r.send([
      {
        'DeviceList': {
          'Id': id,
          'Devices': [device],
        },
      },
    ]);
    await reading;
    expect(g.devices, isEmpty);
  });
  for (final patch in ['devices.patch', 'slots.patch']) {
    test('DGLAB late refresh preserves newer $patch', () async {
      final requested = Completer<String>();
      final r = await Relay.start((r, frame) {
        if (frame['type'] == 'message') {
          requested.complete(frame['data']['reqId'] as String);
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
      r.send({'type': 'client_attached', 'clientId': 'phone'});
      appEvent(r, {
        't': 'ev',
        'ev': 'devices.snapshot',
        'devices': [coyote('a')],
      });
      await until(() => g.devices.isNotEmpty);
      final reading = g.refresh(), id = await requested.future;
      if (patch == 'devices.patch') {
        appEvent(r, {
          't': 'ev',
          'ev': patch,
          'removed': ['a'],
          'added': [],
        });
        await until(() => g.devices.isEmpty);
      } else {
        appEvent(r, {
          't': 'ev',
          'ev': patch,
          'slots': [
            {
              'slotId': 'a',
              'props': {'power': 79},
            },
          ],
        });
        await until(() => g.devices.single.details['props']['power'] == 79);
      }
      appEvent(r, {
        't': 'resp',
        'reqId': id,
        'result': {
          'devices': [coyote('a')],
        },
      });
      await reading;
      if (patch == 'devices.patch') {
        expect(g.devices, isEmpty);
      } else {
        expect(g.devices.single.details['props']['power'], 79);
      }
    });
  }
  test(
    'DGLAB accumulated state is bounded across individually small patches',
    () async {
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
      r.send({'type': 'client_attached', 'clientId': 'phone'});
      appEvent(r, {
        't': 'ev',
        'ev': 'devices.snapshot',
        'devices': [coyote('a')],
      });
      await until(() => g.devices.isNotEmpty);
      for (var batch = 0; batch < 3; batch++) {
        appEvent(r, {
          't': 'ev',
          'ev': 'slots.patch',
          'slots': [
            {
              'slotId': 'a',
              'props': {for (var i = 0; i < 100; i++) 'field_${batch}_$i': i},
            },
          ],
        });
      }
      await until(() => g.pairingUri == null);
      expect(g.devices, isEmpty);
    },
  );
}
