// Explicit operator-run release diagnostic. No microphone or device access.
import 'dart:io';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:haptics_lab/venice_chat_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{'release_probe': true};
  try {
    await VeniceLocalKey.load().timeout(const Duration(seconds: 10));
    report['key_loaded'] = true;
  } catch (error) {
    report['key_loaded'] = false;
    report['error_type'] = error.runtimeType.toString();
    // Only fixed StateError labels produced by the key loader are permitted.
    if (error is StateError &&
        const [
          'windows_only',
          'profile_missing',
          'key_missing',
          'key_unavailable',
          'key_invalid',
        ].contains(error.message)) {
      report['code'] = error.message;
    }
  }
  final root = Platform.environment['HAPTICS_REPORT_DIR'];
  if (root != null) {
    await File('$root/venice-release-key.json')
        .writeAsString(jsonEncode(report));
  }
  exit(report['key_loaded'] == true ? 0 : 1);
}
