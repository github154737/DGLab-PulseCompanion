import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'Usage: beta_admin.dart <private-state-directory> status|invite5|manage [JSON command]',
    );
    exitCode = 2;
    return;
  }
  final privateDir = Directory(args[0]), command = args[1];
  final export = File(
    '${privateDir.path}/${command == 'invite5' ? 'invites-once' : 'recovery-once'}.json',
  );
  if ((command == 'invite5' || command == 'recover') && await export.exists()) {
    stderr.writeln(
      'Private export already exists; retain it before creating another.',
    );
    exitCode = 2;
    return;
  }
  final token = (await File(
    '${privateDir.path}/owner-token',
  ).readAsString()).trim();
  final http = HttpClient();
  try {
    final path = command == 'status'
        ? 'status'
        : command == 'invite5'
        ? 'invites'
        : command == 'recover'
        ? 'recover'
        : 'manage';
    final req = await http.openUrl(
      command == 'status' ? 'GET' : 'POST',
      Uri.parse(
        'http://127.0.0.1:${Platform.environment['HAPTICS_ADMIN_PORT'] ?? Platform.environment['HAPTICS_PORT'] ?? '8790'}/admin/$path',
      ),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (command != 'status') {
      req.headers.contentType = ContentType.json;
      req.write(command == 'invite5' ? jsonEncode({'count': 5}) : args[2]);
    }
    final response = await req.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) throw StateError('request_failed');
    if (command == 'invite5' || command == 'recover') {
      await export.writeAsString(text, flush: true);
      stdout.writeln(
        'Codes exported privately. Do not place this file in reports or packages.',
      );
    } else {
      stdout.writeln(text);
    }
  } catch (_) {
    stderr.writeln('Admin action failed; no credential details logged.');
    exitCode = 1;
  } finally {
    http.close(force: true);
  }
}
