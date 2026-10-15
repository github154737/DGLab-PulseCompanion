// Operator-only connectivity smoke: no microphone, playback, or device calls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:haptics_lab/local_owner.dart';

Future<void> main(List<String> args) async {
  final result = <String, dynamic>{
    'microphone_used': false,
    'device_used': false,
  };
  WebSocket? socket;
  try {
    final api = await LocalOwner.connect('http://127.0.0.1:8790');
    result['owner_authenticated'] = true;
    socket = await api.connect();
    final done = Completer<void>();
    var requested = false;
    final events = <String, int>{};
    socket.listen(
      (raw) {
        final event = jsonDecode(raw as String) as Map<String, dynamic>;
        final type = event['type'] as String;
        events[type] = (events[type] ?? 0) + 1;
        if (type == 'session.updated' && !requested) {
          requested = true;
          socket!.add(
            jsonEncode({
              'type': 'conversation.item.create',
              'item': {
                'type': 'message',
                'role': 'user',
                'content': [
                  {'type': 'input_text', 'text': '请只回复：连接测试成功。'},
                ],
              },
            }),
          );
          socket.add(jsonEncode({'type': 'response.create'}));
        }
        if (type == 'response.done' && !done.isCompleted) {
          result['response_status'] = event['response']['status'];
          result['usage'] = event['response']['usage'];
          done.complete();
        }
        if ((type == 'error' || type == 'service.closed') &&
            !done.isCompleted) {
          done.completeError(StateError('provider_or_service_closed'));
        }
      },
      onError: (Object _) {
        if (!done.isCompleted) done.completeError(StateError('socket_error'));
      },
      onDone: () {
        if (!done.isCompleted) done.completeError(StateError('socket_closed'));
      },
    );
    socket.add(
      jsonEncode({
        'type': 'session.update',
        'session': {
          'modalities': ['text', 'audio'],
          'voice': 'Tina',
          'input_audio_format': 'pcm',
          'output_audio_format': 'pcm',
          'turn_detection': null,
          'instructions': '你是连接测试助手。只回复一句简短中文。',
          'tools': [],
        },
      }),
    );
    await done.future.timeout(const Duration(seconds: 45));
    result['events'] = events;
    result['ok'] = result['response_status'] == 'completed';
  } catch (error) {
    result['ok'] = false;
    result['error'] = 'connectivity_check_failed';
    result['error_type'] = '${error.runtimeType}';
    exitCode = 1;
  } finally {
    await socket?.close();
    final serialized = const JsonEncoder.withIndent('  ').convert(result);
    if (args.length == 1) await File(args.single).writeAsString(serialized);
    stdout.writeln(serialized);
  }
}
