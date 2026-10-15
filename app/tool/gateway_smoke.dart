import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:haptics_lab/device_gateway.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError('gateway_smoke <fixture-exe> <report>');
  }
  final process = await Process.start(args[0], []);
  final ready = Completer<int>(),
      observations = <dynamic>[],
      errors = <String>[];
  final out = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        final data = jsonDecode(line);
        if (data['ready'] == true && data['physical_managers'] == 0) {
          ready.complete(data['port'] as int);
        }
        if (data['observation'] != null) observations.add(data['observation']);
      });
  final err = process.stderr.transform(utf8.decoder).listen(errors.add);
  final g = IntifaceGateway();
  try {
    final port = await ready.future.timeout(const Duration(seconds: 20));
    await g.connect(Uri.parse('ws://127.0.0.1:$port'));
    await g.scan();
    if (g.devices.length != 1 ||
        g.devices.single.kind != 'vibration' ||
        g.devices.single.channels != 1) {
      throw StateError('upstream capability mismatch');
    }
    if (observations.isNotEmpty) {
      throw StateError('discovery emitted an output');
    }
    final report = {
      'passed': true,
      'gateway': 'IntifaceGateway',
      'upstream': 'buttplug_server 12.0.1',
      'physical_managers': 0,
      'device_count': g.devices.length,
      'output_commands': 0,
      'checks': [
        'v3 handshake',
        'five-second explicit scan',
        'device list refresh',
        'Vibrate capability parsed',
        'discovery sent no output',
      ],
      'stderr': errors,
    };
    await File(args[1])
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln(jsonEncode(report));
  } finally {
    await g.close();
    process.kill();
    await out.cancel();
    await err.cancel();
  }
}
