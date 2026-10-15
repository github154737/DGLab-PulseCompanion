import 'dart:convert';
import 'dart:io';

/// Read-only models endpoint probe. Does not generate text or upload audio.
Future<void> main(List<String> args) async {
  final config = jsonDecode(await File(args[0]).readAsString()) as Map;
  final key = RegExp(r'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}')
      .firstMatch(await File(config['keyFile']).readAsString())!
      .group(0)!;
  final rows = <Map<String, Object>>[];
  for (var i = 0; i < 16; i++) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final clock = Stopwatch()..start();
    var stage = 'connect';
    final row = <String, Object>{'index': i};
    try {
      final request = await client.getUrl(
        Uri.parse('https://api.venice.ai/api/v1/models'),
      );
      row['connect_ms'] = clock.elapsedMilliseconds;
      stage = 'response';
      request.headers.set('Authorization', 'Bearer $key');
      final response = await request.close();
      row['status'] = response.statusCode;
      await response.drain<void>();
    } on SocketException catch (e) {
      row['error'] = 'socket';
      row['os_code'] = e.osError?.errorCode ?? -1;
    } on HandshakeException {
      row['error'] = 'tls';
    } catch (_) {
      row['error'] = 'other';
    } finally {
      client.close(force: true);
    }
    row.addAll({'stage': stage, 'ms': clock.elapsedMilliseconds});
    rows.add(row);
    stdout.writeln(jsonEncode(row));
  }
  await File(args[1])
      .writeAsString(const JsonEncoder.withIndent('  ').convert(rows));
}
