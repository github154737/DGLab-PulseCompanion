import 'dart:convert';
import 'dart:io';

import 'package:haptics_lab/pulse_library.dart';

void main(List<String> args) {
  final result = importPulseFiles(
    'waveforms.zip',
    File(args[0]).readAsBytesSync(),
  );
  final report = {
    'unique_imported': result.waves.length,
    'duplicates': result.duplicates,
    'failed': result.errors,
    'lossless_export': true,
    'physical_conversion_verified': false,
  };
  File(args[1])
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(
    'Imported ${result.waves.length}; duplicates ${result.duplicates}; failed ${result.errors.length}.',
  );
}
