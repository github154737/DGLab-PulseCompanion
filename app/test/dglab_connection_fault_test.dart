import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/device_gateway.dart';
import 'package:haptics_lab/physical_output.dart';

import 'gateway_test.dart' show Relay, until, coyote, appEvent;
import 'experience_test.dart' show output;

void main() {
  for (final fault in [
    'empty',
    'disconnected',
    'missing_state',
    'lost_during_arm',
    'app_drop',
    'timeout',
  ]) {
    test('real V4 socket without hardware: $fault', () async {
      var answer = true;
      final r = await Relay.start((r, frame) {
        if (frame['type'] != 'message' || !answer) return;
        final data = frame['data'], op = data['data'];
        appEvent(r, {
          't': 'resp',
          'reqId': data['reqId'],
          'result': data['m'] == 'device.op.clear'
              ? <String, dynamic>{}
              : {
                  'type': op['t'],
                  'reason': 'completed',
                  'slotId': op['s'],
                  'channel': op['c'],
                },
        });
      });
      final g = DglabV4Gateway(), p = PhysicalOutput();
      addTearDown(() async {
        await p.stop();
        p.dispose();
        await g.close();
        await r.close();
      });
      final connecting = g.connect(r.uri);
      await r.ready.future;
      r.send({'type': 'hello', 'clientId': 'test-controller'});
      await connecting;
      expect(
        Uri.parse(g.pairingUri!.queryParameters['url']!).queryParameters['tid'],
        'test-controller',
      );
      r.send({'type': 'client_attached', 'clientId': 'phone'});
      final descriptor = coyote('slot');
      if (fault == 'disconnected') {
        descriptor['props'] = {'connectState': 'disconnected'};
      }
      if (fault == 'missing_state') descriptor['slotState'] = {};
      appEvent(r, {
        't': 'ev',
        'ev': 'devices.snapshot',
        'devices': fault == 'empty' ? [] : [descriptor],
      });
      await until(
        () =>
            g.pairedAppCount == 1 && (fault == 'empty' || g.devices.isNotEmpty),
      );
      if (['empty', 'disconnected', 'missing_state'].contains(fault)) {
        expect(p.canArm, false);
        if (g.devices.isNotEmpty) {
          await expectLater(p.bind(g, g.devices.single), throwsStateError);
        }
        await expectLater(p.arm(), throwsStateError);
        expect(
          r.received,
          isEmpty,
        ); // Pairing and unavailable slots never trigger output.
        return;
      }
      await p.bind(g, g.devices.single);
      expect(p.canArm, true);
      if (fault == 'lost_during_arm') {
        answer = false;
        final arming = p.arm();
        final rejected = expectLater(arming, throwsStateError);
        await until(() => r.received.length == 3);
        appEvent(r, {
          't': 'ev',
          'ev': 'slots.patch',
          'slots': [
            {
              'slotId': 'slot',
              'slotState': {'hasDevice': false},
            },
          ],
        });
        await rejected;
        expect(p.armed, false);
        expect(
          r.received.every(
            (f) =>
                f['data']['m'] == 'device.op.clear' ||
                f['data']['data']['t'] == 7,
          ),
          true,
        );
        return;
      }
      await p.arm();
      expect(p.armed, true);
      r.received.clear();
      if (fault == 'app_drop') {
        r.send({'type': 'client_disconnected', 'clientId': 'phone'});
        await until(() => !p.armed && !p.stopping);
        expect(p.unknown, true);
        r.send({'type': 'client_attached', 'clientId': 'phone'});
        appEvent(r, {
          't': 'ev',
          'ev': 'devices.snapshot',
          'devices': [descriptor],
        });
        await until(() => g.devices.isNotEmpty);
        expect(
          p.canArm,
          false,
        ); // Never auto resume an unconfirmed physical stop.
        p.consume(output());
        expect(r.received, isEmpty);
      } else {
        answer = false;
        p.consume(output());
        await Future<void>.delayed(const Duration(milliseconds: 4300));
        expect(p.armed, false);
        expect(p.unknown, true);
        final sent = r.received.length;
        p.consume(output());
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(r.received.length, sent);
      }
    });
  }
}
