import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/continuous_voice.dart';

void main() {
  final path = Platform.environment['HAPTICS_VOICE_FIXTURE'];
  test(
    'existing neutral speech WAV creates bounded endpoint segments',
    () {
      final wav = File(path!).readAsBytesSync();
      final header = ByteData.sublistView(wav);
      Uint8List? pcm;
      for (var offset = 12; offset + 8 <= wav.length;) {
        final name = String.fromCharCodes(wav.sublist(offset, offset + 4));
        final length = header.getUint32(offset + 4, Endian.little);
        if (name == 'fmt ') {
          expect(header.getUint16(offset + 8, Endian.little), 1);
          expect(header.getUint16(offset + 10, Endian.little), 1);
          expect(header.getUint32(offset + 12, Endian.little), 16000);
          expect(header.getUint16(offset + 22, Endian.little), 16);
        }
        if (name == 'data') {
          pcm = Uint8List.sublistView(wav, offset + 8, offset + 8 + length);
        }
        offset += 8 + length + length % 2;
      }
      expect(pcm, isNotNull);
      final detector = VoiceEndpoint();
      final input = Uint8List.fromList([...pcm!, ...Uint8List(32000)]);
      final lengths = <int>[];
      for (var i = 0; i < input.length; i += 640) {
        final output = detector.add(
          Uint8List.sublistView(input, i, (i + 640).clamp(0, input.length)),
        );
        if (output != null) lengths.add(output.length);
      }
      expect(
        lengths,
        isNotEmpty,
        reason: 'Natural speech must pass the endpoint detector, not just synthetic sine waves.',
      );
      expect(lengths.every((n) => n > 8000 && n < 660000), true);
      expect(detector.retainedBytes, lessThanOrEqualTo(10240));
    },
    skip: path == null
        ? 'Set HAPTICS_VOICE_FIXTURE to a neutral 16 kHz PCM16 WAV.'
        : false,
  );
}
