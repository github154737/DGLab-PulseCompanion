import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/venice_transcription.dart';

void main() {
  test('WAV is mono PCM16 16k and rejects invalid sizes', () {
    final pcm = Uint8List.fromList(List.generate(3200, (i) => i % 256));
    final wav = pcmToWav(pcm);
    final data = ByteData.sublistView(wav);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(data.getUint32(4, Endian.little), wav.length - 8);
    expect(data.getUint32(24, Endian.little), 16000);
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint16(34, Endian.little), 16);
    expect(wav.sublist(44), pcm);
    for (final size in [0, 1, 1920002]) {
      expect(
        () => pcmToWav(Uint8List(size)),
        throwsA(isA<ModelServiceException>()),
      );
    }
  });

  test(
    'multipart sends selected model and binary WAV, then reads Chinese text',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final wav = pcmToWav(Uint8List(3200));
      server.listen((req) async {
        expect(req.uri.path, '/api/v1/audio/transcriptions');
        expect(req.headers.value('authorization'), 'Bearer fixture');
        final boundary = req.headers.contentType!.parameters['boundary']!;
        final body = await req.fold<List<int>>(
          [],
          (all, part) => all..addAll(part),
        );
        final text = latin1.decode(body);
        expect(text, contains('name="model"\r\n\r\nstt-xai-v1\r\n'));
        expect(text, contains('name="file"; filename="speech.wav"'));
        expect(text, contains('Content-Type: audio/wav\r\n\r\nRIFF'));
        expect(text.endsWith('\r\n--$boundary--\r\n'), true);
        expect(body.length, req.headers.contentLength);
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'text': '你好，今天怎么样？'}));
        await req.response.close();
      });
      final client = VeniceTranscriber(
        apiKey: 'fixture',
        endpoint: Uri.parse(
          'http://127.0.0.1:${server.port}/api/v1/audio/transcriptions',
        ),
      );
      expect(await client.transcribe(wav), '你好，今天怎么样？');
    },
  );

  test('errors are sanitized and never automatically retried; redirects not followed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var calls = 0, status = 402;
    server.listen((req) async {
      calls++;
      await req.drain<void>();
      req.response.statusCode = status;
      req.response.headers.set(
        'location',
        'http://127.0.0.1:${server.port}/leak',
      );
      req.response.write('fixture-private-key-and-transcript');
      await req.response.close();
    });
    for (final code in [401, 402, 413, 415, 429, 302, 500]) {
      status = code;
      final client = VeniceTranscriber(
        apiKey: 'fixture',
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/stt'),
      );
      await expectLater(
        client.transcribe(pcmToWav(Uint8List(3200))),
        throwsA(
          isA<ModelServiceException>().having(
            (e) => e.message,
            'sanitized',
            isNot(contains('fixture-private')),
          ),
        ),
      );
    }
    expect(calls, 7);
  });

  test('empty or malformed response cannot become a chat request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var response = '';
    server.listen((req) async {
      await req.drain<void>();
      req.response.write(response);
      await req.response.close();
    });
    for (final body in [
      '{}',
      '{"text":"   "}',
      '{"text":32}',
      'not-json',
      jsonEncode({'text': 'a' * 2001}),
    ]) {
      response = body;
      final client = VeniceTranscriber(
        apiKey: 'fixture',
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/stt'),
      );
      await expectLater(
        client.transcribe(pcmToWav(Uint8List(3200))),
        body == '{"text":"   "}'
            ? throwsA(isA<NoSpeechDetected>())
            : throwsA(
                isA<ModelServiceException>().having(
                  (e) => e.code,
                  'not normal silence',
                  isNot('no_speech'),
                ),
              ),
      );
    }
  });

  test('cancel aborts an in-flight upload response without retry', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = Completer<void>();
    server.listen((req) async {
      await req.drain<void>();
      seen.complete();
    });
    final client = VeniceTranscriber(
      apiKey: 'fixture',
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/stt'),
    );
    final future = client.transcribe(pcmToWav(Uint8List(3200)));
    final failure = expectLater(future, throwsA(isA<ModelServiceException>()));
    await seen.future;
    client.cancel();
    await failure;
  });
}
