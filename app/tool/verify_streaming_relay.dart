// Opt-in live check: two small paid requests, no supplied conversation content.
// Usage: dart run tool/verify_streaming_relay.dart <private-config.json>
// Only timing/status metadata is printed. Does not replace the running relay.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Standalone Dart CLI intentionally runs without Flutter's package resolution.
// ignore: avoid_relative_lib_imports
import '../lib/chat_stream.dart';
import 'venice_relay.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Private config path required');
  final config = jsonDecode(await File(args.single).readAsString()) as Map;
  final keyText = await File(config['keyFile'] as String).readAsString();
  final key = RegExp(r'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}')
      .firstMatch(keyText)
      ?.group(0);
  if (key == null) throw StateError('Missing supplier key');
  const token = 'isolated-local-verification';
  final relay = VeniceRelay(
    key: key,
    token: token,
    proxy: config['proxy'] as String?,
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(relay.handle);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    for (final kind in ['chat', 'speech']) {
      final clock = Stopwatch()..start();
      int? firstMs;
      final request = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/api/v1/${kind == 'chat' ? 'chat/completions' : 'audio/speech'}',
        ),
      );
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', 'Bearer $token');
      request.write(
        jsonEncode(
          kind == 'chat'
              ? {
                  'model': 'venice-uncensored-1-2',
                  'stream': true,
                  'max_tokens': 100,
                  'messages': [
                    {'role': 'user', 'content': '请用两句简短中文说明今天的语音功能测试已开始。'},
                  ],
                }
              : {
                  'model': 'tts-xai-v1',
                  'input': '你好，语音功能测试已经开始。我们正在检查声音是否能够及时播放。',
                  'voice': 'eve',
                  'language': 'zh',
                  'response_format': 'mp3',
                  'speed': 1,
                  'streaming': true,
                },
        ),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      if (response.statusCode != 200) {
        stdout.writeln(
          jsonEncode({
            'kind': kind,
            'status': response.statusCode,
            'passed': false,
          }),
        );
        await response.drain<void>();
        exitCode = 1;
        continue;
      }
      var count = 0;
      if (kind == 'chat') {
        await readChatStream(
          response,
          onText: (_) {
            firstMs ??= clock.elapsedMilliseconds;
          },
        );
      } else {
        await for (final chunk in response) {
          if (chunk.isNotEmpty) firstMs ??= clock.elapsedMilliseconds;
          count += chunk.length;
        }
      }
      stdout.writeln(
        jsonEncode({
          'kind': kind,
          'status': 200,
          'first_ms': firstMs,
          'complete_ms': clock.elapsedMilliseconds,
          if (kind == 'speech') 'audio_bytes': count,
          'passed': firstMs != null && (kind != 'speech' || count >= 32),
        }),
      );
    }
  } catch (_) {
    stdout.writeln('{"passed":false,"error":"live_stream_check_failed"}');
    exitCode = 1;
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
}
