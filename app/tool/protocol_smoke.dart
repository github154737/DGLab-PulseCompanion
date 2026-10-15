import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/model_provider.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError('Usage: protocol_smoke <fixture-exe> <report-json>');
  }
  final observations = <Map<String, dynamic>>[];
  final errors = <String>[];
  final ready = Completer<int>();
  final process = await Process.start(args[0], []);
  final stdoutSub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        try {
          final data = jsonDecode(line);
          if (data['ready'] == true &&
              data['physical_managers'] == 0 &&
              !ready.isCompleted) {
            ready.complete(data['port'] as int);
          }
          if (data['observation'] is Map) {
            observations.add(Map<String, dynamic>.from(data['observation']));
          }
        } catch (_) {
          errors.add(line);
        }
      });
  final stderrSub = process.stderr.transform(utf8.decoder).listen(errors.add);
  WebSocket? socket;
  StreamSubscription<dynamic>? socketSub;
  final core = CoreBridge();
  core.call({'op': 'reset_simulation'});
  final checks = <String>[];
  final requests = <int, Completer<Map<String, dynamic>>>{};
  var counter = 0;
  final device = Completer<Map<String, dynamic>>();
  Future<Map<String, dynamic>> request(
    String type,
    Map<String, dynamic> payload,
  ) async {
    final id = ++counter, result = Completer<Map<String, dynamic>>();
    requests[id] = result;
    socket!.add(
      jsonEncode([
        {
          type: {'Id': id, ...payload},
        },
      ]),
    );
    try {
      final response = await result.future.timeout(const Duration(seconds: 5));
      if (response.containsKey('Error')) throw StateError(jsonEncode(response));
      return response;
    } finally {
      requests.remove(id);
    }
  }

  void check(bool condition, String name) {
    if (!condition) throw StateError(name);
    checks.add(name);
  }

  try {
    final port = await ready.future.timeout(const Duration(seconds: 20));
    socket = await WebSocket.connect('ws://127.0.0.1:$port');
    socketSub = socket.listen(
      (raw) {
        for (final dynamic item in jsonDecode(raw as String)) {
          final obj = Map<String, dynamic>.from(item);
          final body = Map<String, dynamic>.from(obj.values.first as Map);
          final id = body['Id'];
          if (obj.containsKey('DeviceAdded') && !device.isCompleted) {
            device.complete(body);
          }
          if (requests[id] case final pending? when !pending.isCompleted) {
            pending.complete(obj);
          }
        }
      },
      onDone: () {
        for (final pending in requests.values) {
          if (!pending.isCompleted) {
            pending.completeError(StateError('fixture disconnected'));
          }
        }
      },
    );
    final info = await request('RequestServerInfo', {
      'ClientName': 'AI Haptics isolated test',
      'MessageVersion': 3,
    });
    check(info.containsKey('ServerInfo'), 'real server JSON handshake');
    await request('StartScanning', {});
    final found = await device.future.timeout(const Duration(seconds: 5));
    final index = found['DeviceIndex'];
    check(
      found['DeviceMessages']['ScalarCmd'][0]['ActuatorType'] == 'Vibrate',
      'upstream simulated vibrate capability discovered',
    );
    await request('StopScanning', {});

    core.call({'op': 'connect', 'device_id': 'sim_single'});
    core.call({'op': 'authorize', 'limit': 0.3, 'lease_ms': 30000});
    final ticket = core.call({'op': 'begin_ai'})['result']['ticket'];
    final reply = await const FakeModelProvider(delay: Duration.zero)
        .respond('脉冲', 'sim_single');
    final start = core.call({
      'op': 'complete_ai',
      'ticket': ticket,
      'response': jsonEncode(reply.intent),
    });
    check(start['ok'] == true, 'fake model intent authorized by Rust');
    for (var i = 0; i < 8; i++) {
      final state = core.call({'op': 'snapshot'})['state'];
      check(state['phase'] == 'playing', 'authorized playback sample $i');
      final value = state['output'][0] as num;
      await request('ScalarCmd', {
        'DeviceIndex': index,
        'Scalars': [
          {'Index': 0, 'Scalar': value, 'ActuatorType': 'Vibrate'},
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    final oldTicket = core.call({'op': 'begin_ai'})['result']['ticket'];
    core.call({'op': 'stop'});
    await request('StopAllDevices', {});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final stopCount = observations.length;
    final stale = core.call({
      'op': 'complete_ai',
      'ticket': oldTicket,
      'response': jsonEncode(reply.intent),
    });
    check(stale['ok'] == false, 'late action refused after stop');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    check(
      observations.any((o) => (o['value'] as num) > 0),
      'real upstream output observations received',
    );
    check(
      observations.every(
        (o) => (o['value'] as num) >= 0 && (o['value'] as num) <= 30,
      ),
      'all observed values bounded by selected simulation limit',
    );
    check(observations.last['value'] == 0, 'upstream simulator observed stop');
    check(
      observations.skip(stopCount).every((o) => o['value'] == 0),
      'no nonzero observation after stale action',
    );
    final report = {
      'passed': true,
      'simulation_only': true,
      'physical_managers': 0,
      'server': 'buttplug_server 12.0.1',
      'wire_protocol': 3,
      'checks': checks,
      'observations': observations,
      'stderr': errors,
    };
    await File(args[1])
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln(
      jsonEncode({
        'passed': true,
        'checks': checks.length,
        'observations': observations.length,
      }),
    );
  } catch (e) {
    await File(args[1]).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'passed': false,
        'checks': checks,
        'observations': observations,
        'error': e.toString(),
        'stderr': errors,
      }),
    );
    rethrow;
  } finally {
    core.call({'op': 'stop'});
    await socket?.close();
    await socketSub?.cancel();
    process.kill();
    await stdoutSub.cancel();
    await stderrSub.cancel();
  }
}
