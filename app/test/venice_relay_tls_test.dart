import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_route.dart';
import 'package:haptics_lab/venice_transcription.dart';

void main() {
  test(
    'configured Flutter route trusts pinned certificate and reaches relay',
    () async {
      expect(VeniceRoute.isRelay, true);
      expect(VeniceRoute.base.scheme, 'https');
      final transcriber = VeniceTranscriber(apiKey: VeniceRoute.relayToken);
      expect(transcriber.endpoint.origin, VeniceRoute.base.origin);
      final client = VeniceRoute.client(VeniceRoute.base)
        ..connectionTimeout = const Duration(seconds: 15);
      // Desktop diagnostic only. Production mobile routing remains DIRECT.
      final testProxy = Platform.environment['RELAY_TEST_PROXY'];
      if (testProxy != null && testProxy.isNotEmpty) {
        client.findProxy = (_) => 'PROXY $testProxy';
      }
      try {
        final request = await client.getUrl(VeniceRoute.endpoint('health'));
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${VeniceRoute.relayToken}',
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    },
    skip: !const bool.fromEnvironment('RELAY_LIVE_CHECK'),
  );
}
