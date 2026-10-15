// Read-only relay probe. Both peers belong to this test; no hardware is involved.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:haptics_lab/device_gateway.dart';

Future<void> main() async {
  final gateway = DglabV4Gateway();
  WebSocket? peer;
  final report = <String, Object>{'real_hardware_tested': false};
  try {
    await gateway.connect(Uri.parse('wss://trex.dungeon-lab.cn/v4'));
    final pairing = gateway.pairingUri!;
    report['official_pairing_url'] =
        pairing.host == 'dungeon-lab.cn' &&
        pairing.queryParameters['action'] == 'socket';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    client.findProxy = (_) => 'DIRECT';
    try {
      peer = await WebSocket.connect(
        pairing.queryParameters['url']!,
        customClient: client,
      ).timeout(const Duration(seconds: 10));
    } finally {
      client.close();
    }
    var outputRequests = 0;
    peer.listen((raw) {
      final frame = jsonDecode(raw as String);
      if (frame['type'] == 'heartbeat') peer!.add(jsonEncode({'type': 'ping'}));
      if (frame['type'] != 'message') return;
      final data = frame['data'];
      if (data is Map && data['m'] == 'devices.get') {
        peer!.add(
          jsonEncode({
            'type': 'message',
            'data': {
              't': 'resp',
              'reqId': data['reqId'],
              'result': {'devices': []},
            },
          }),
        );
      } else if (data is Map && data['m'].toString().startsWith('device.op')) {
        outputRequests++;
      }
    });
    final until = DateTime.now().add(const Duration(seconds: 8));
    while (gateway.pairedAppCount != 1) {
      if (DateTime.now().isAfter(until)) throw TimeoutException('attach');
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    report['test_peer_attached'] = true;
    peer.add(
      jsonEncode({
        'type': 'message',
        'data': {'t': 'ev', 'ev': 'devices.snapshot', 'devices': []},
      }),
    );
    await gateway.refresh();
    report['empty_device_list_read'] = gateway.devices.isEmpty;
    report['output_requests'] = outputRequests;
    await peer.close();
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (gateway.pairedAppCount != 0) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('detach');
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    report['test_peer_detached'] = true;
    report['ok'] = true;
  } catch (error) {
    report['ok'] = false;
    report['error_type'] = error.runtimeType.toString();
    exitCode = 1;
  } finally {
    await peer?.close();
    await gateway.close();
  }
  // Never print the live pairing URL or client identifiers.
  stdout.writeln(jsonEncode(report));
}
