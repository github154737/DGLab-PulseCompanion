import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/device_gateway.dart';

import 'gateway_test.dart' show Relay, until, coyote, appEvent;

void main() {
  test(
    'V4 wire operations preserve client/slot/channel and validate completion',
    () async {
      final relay = await Relay.start((r, frame) {
        if (frame['type'] != 'message') return;
        final data = frame['data'], operation = data['data'];
        final response = {
          't': 'resp',
          'reqId': data['reqId'],
          'result': data['m'] == 'device.op.clear'
              ? <String, dynamic>{}
              : {
                  'type': operation['t'],
                  'reason': 'completed',
                  'slotId': operation['s'],
                  'channel': operation['c'],
                },
        };
        appEvent(r, response);
      });
      final g = DglabV4Gateway();
      addTearDown(() async {
        await g.close();
        await relay.close();
      });
      final connecting = g.connect(relay.uri);
      await relay.ready.future;
      relay.send({'type': 'hello', 'clientId': 'controller'});
      await connecting;
      relay.send({'type': 'client_attached', 'clientId': 'phone'});
      appEvent(relay, {
        't': 'ev',
        'ev': 'devices.snapshot',
        'devices': [coyote('slot')],
      });
      await until(() => g.devices.length == 1);
      await g.operate(g.devices.single, {
        't': 0,
        'c': 1,
        'p': 1,
        'd': 100,
        'im': true,
        'ver': 3,
        'v': ['1414141432323232'],
      });
      await g.operate(g.devices.single, {
        't': 4,
        'c': 1,
        'd': 200,
        'im': true,
        'v': 5,
      });
      await g.operate(g.devices.single, {}, clear: true);
      expect(relay.received.map((f) => f['clientId']), everyElement('phone'));
      expect(
        relay.received.map((f) => f['data']['data']['s']),
        everyElement('slot'),
      );
      expect(relay.received.last['data']['m'], 'device.op.clear');
      expect(relay.received.first['data']['data']['v'], ['1414141432323232']);
    },
  );
  test(
    'V4 rejects mismatched channel completion instead of reporting success',
    () async {
      final relay = await Relay.start((r, frame) {
        if (frame['type'] == 'message') {
          appEvent(r, {
            't': 'resp',
            'reqId': frame['data']['reqId'],
            'result': {
              'type': 7,
              'reason': 'completed',
              'channel': 1,
              'slotId': 'slot',
            },
          });
        }
      });
      final g = DglabV4Gateway();
      addTearDown(() async {
        await g.close();
        await relay.close();
      });
      final opening = g.connect(relay.uri);
      await relay.ready.future;
      relay.send({'type': 'hello', 'clientId': 'controller'});
      await opening;
      relay.send({'type': 'client_attached', 'clientId': 'phone'});
      appEvent(relay, {
        't': 'ev',
        'ev': 'devices.snapshot',
        'devices': [coyote('slot')],
      });
      await until(() => g.devices.isNotEmpty);
      await expectLater(
        g.operate(g.devices.single, {'t': 7, 'c': 0, 'v': 0}),
        throwsStateError,
      );
    },
  );
}
