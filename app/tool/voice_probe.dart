import 'dart:io';

import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/realtime_probe_server.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/voice_probe.dart <sanitized-report-path>',
    );
    exitCode = 2;
    return;
  }
  final server = ProbeServer(
    CoreBridge().call,
    Directory.fromUri(Platform.script.resolve('voice_probe/')),
    File(args.single),
  );
  try {
    await server.start(port: 8787);
    stdout.writeln('AI Haptics voice probe: ${server.origin}');
    stdout.writeln(
      'Simulation only. Enter credentials privately in the local browser. No audio or secrets are logged.',
    );
  } catch (_) {
    stderr.writeln(
      'Unable to start voice probe. Check port 8787 and native library.',
    );
    exitCode = 1;
  }
}
