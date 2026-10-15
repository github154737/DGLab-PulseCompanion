import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_chat_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('embedded local key does not access the Windows vault', () async {
    var vaultCalls = 0;
    const channel = MethodChannel('aihaptics/pcm');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      vaultCalls++;
      throw PlatformException(code: 'key_missing');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await VeniceLocalKey.load(), VeniceLocalKey.embeddedKey);
    expect(vaultCalls, 0);
  }, skip: !VeniceLocalKey.isEmbedded);
}
