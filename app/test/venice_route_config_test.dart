import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_route.dart';

void main() {
  test('relay description matches selected deployment, without LAN instructions for cloud', () {
    if (!VeniceRoute.isRelay) {
      expect(VeniceRoute.isCloudRelay, false);
      expect(VeniceRoute.description, contains('手机直连'));
    } else if (VeniceRoute.relayKind == 'cloud') {
      expect(VeniceRoute.isCloudRelay, true);
      expect(VeniceRoute.description, contains('云中继'));
      expect(VeniceRoute.connectionLabel, contains('云中继'));
      expect(VeniceRoute.timeoutMessage, contains('云中继'));
      expect(VeniceRoute.timeoutMessage, isNot(contains('同一 Wi-Fi')));
      expect(
        VeniceRoute.networkFailureMessage,
        isNot(contains('Venice 是否可访问')),
      );
      expect(VeniceRoute.description, isNot(contains('电脑须保持开机')));
    } else {
      expect(VeniceRoute.isCloudRelay, false);
      expect(VeniceRoute.description, contains('电脑须保持开机'));
    }
  });

  test(
    'audio route authorization cannot leak to another origin or endpoint',
    () {
      if (!VeniceRoute.isRelay) return;
      expect(VeniceRoute.accepts(VeniceRoute.endpoint('audio/speech')), true);
      expect(
        VeniceRoute.accepts(VeniceRoute.endpoint('audio/transcriptions')),
        true,
      );
      expect(
        VeniceRoute.accepts(
          Uri.parse('https://example.com/api/v1/audio/speech'),
        ),
        false,
      );
      expect(
        VeniceRoute.accepts(VeniceRoute.endpoint('chat/completions')),
        false,
      );
      expect(
        VeniceRoute.accepts(
          VeniceRoute.endpoint('audio/speech').replace(scheme: 'http'),
        ),
        false,
      );
    },
  );
}
