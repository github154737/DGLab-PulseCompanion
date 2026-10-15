import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/network_diagnostics.dart';

void main() {
  test('network trace contains stages but no key or response body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      await r.drain<void>();
      r.response.statusCode = 401;
      r.response.write('private-server-body');
      await r.response.close();
    });
    final p = ApiModelProvider(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1'),
      model: 'fixture',
      apiKey: 'private-fixture-key',
      mode: ApiReplyMode.chat,
    );
    await expectLater(
      p.respond('private-user-message', ''),
      throwsA(isA<ModelServiceException>()),
    );
    expect(NetworkTrace.report, contains('HTTP 401'));
    for (final private in [
      'private-fixture-key',
      'private-server-body',
      'private-user-message',
    ]) {
      expect(NetworkTrace.report, isNot(contains(private)));
    }
  });
}
