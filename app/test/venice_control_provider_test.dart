import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_control_provider.dart';
import 'package:haptics_lab/venice_control_reply.dart';
import 'package:haptics_lab/venice_wave_session.dart';

import '../tool/venice_relay.dart';

void main() {
  test('planner factory crosses relay with GLM, 512 tokens and unchanged prompt', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Map<String, dynamic>>[];
    upstream.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer supplier-fixture');
      requests.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {
                'content': '{"action":"hold"}',
                'reasoning_content':
                    'Fixture reasoning is not the control command.',
              },
            },
          ],
        }),
      );
      await request.response.close();
    });
    final relay = VeniceRelay(
      key: 'supplier-fixture',
      token: 'phone-fixture',
      upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(relay.handle);
    final session = VeniceWaveSession()..grant();
    final snapshot = session.snapshot();
    final provider = createVeniceControlProvider(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
      apiKey: 'phone-fixture',
      state: snapshot,
    );
    addTearDown(() async {
      provider.cancel();
      session.dispose();
      relay.dispose();
      await server.close(force: true);
      await upstream.close(force: true);
    });
    final reply = await provider.respond('保持现在这样。', '');
    expect(decodeControlReply(reply.text), {'action': 'hold'});
    final body = requests.single;
    expect(body['model'], 'z-ai-glm-5-3-flash');
    expect(body['max_tokens'], 512);
    expect(body['temperature'], .2);
    expect(body['stream'], false);
    expect(body['response_format'], {'type': 'json_object'});
    expect(body.containsKey('venice_parameters'), false);
    expect(body.containsKey('reasoning'), false);
    expect(body.containsKey('reasoning_effort'), false);
    expect(body['messages'], [
      {
        'role': 'system',
        'content':
            '${VeniceWaveSession.plannerPrompt}\nLocal state: ${jsonEncode(snapshot)}',
      },
      {'role': 'user', 'content': '保持现在这样。'},
    ]);
  });
}
