import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  await integrationDriver(
    responseDataCallback: (data) async {
      final directory = Directory(
        Platform.environment['HAPTICS_REPORT_DIR'] ?? 'build/evidence',
      );
      await directory.create(recursive: true);
      await File('${directory.path}/windows-integration.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    },
  );
}
