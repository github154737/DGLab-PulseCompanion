import 'dart:convert';

/// Strict, bounded SSE decoding shared by the transport and fixture tests.
/// Only visible content is emitted; reasoning and tool deltas are never spoken.
Future<({String text, bool truncated})> readChatStream(
  Stream<List<int>> bytes, {
  required void Function(String) onText,
}) async {
  var size = 0;
  var text = '';
  String? reason;
  var done = false;
  var event = <String>[];
  void dispatch() {
    if (event.isEmpty) return;
    final payload = event.join('\n');
    event = [];
    if (payload == '[DONE]') {
      done = true;
      return;
    }
    if (done) throw const FormatException('data_after_done');
    final value = jsonDecode(payload);
    if (value is! Map || value['error'] != null) {
      throw const FormatException('invalid_event');
    }
    final choices = value['choices'];
    if (choices is! List) throw const FormatException('missing_choices');
    if (choices.isEmpty) return; // usage event
    if (choices.length != 1 || choices.first is! Map) {
      throw const FormatException('multiple_choices');
    }
    final choice = choices.first as Map;
    final delta = choice['delta'];
    if (delta is! Map ||
        delta['tool_calls'] != null ||
        delta['function_call'] != null) {
      throw const FormatException('unexpected_tool');
    }
    final part = delta['content'];
    if (part != null && part is! String) {
      throw const FormatException('invalid_content');
    }
    if (part is String && part.isNotEmpty) {
      if (reason != null || text.length + part.length > 4096) {
        throw const FormatException('invalid_length');
      }
      text += part;
      onText(text);
    }
    final finish = choice['finish_reason'];
    if (finish != null) {
      if (finish != 'stop' && finish != 'length') {
        throw const FormatException('invalid_finish');
      }
      reason = finish as String;
    }
  }

  final limited = bytes.map((part) {
    size += part.length;
    if (size > 262144) throw const FormatException('stream_too_large');
    return part;
  });
  await for (final line
      in limited.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      dispatch();
    } else if (line.startsWith('data:')) {
      event.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
    }
  }
  dispatch();
  if (!done || reason == null || text.trim().isEmpty) {
    throw const FormatException('incomplete_stream');
  }
  return (text: text, truncated: reason == 'length');
}

/// Converts growing visible text into whole sentences without exposing partial
/// machine blocks/code. Once unusual markup is seen, defer the remainder until
/// completion so split delimiters cannot leak into speech.
class SpeechSentences {
  String _seen = '';
  int _sent = 0;
  bool _defer = false;
  int _parts = 0;
  List<String> add(String text, {bool complete = false}) {
    if (!text.startsWith(_seen)) throw const FormatException('non_append_text');
    _seen = text;
    final result = <String>[];
    if (!_defer) {
      for (var i = _sent; i < text.length; i++) {
        // Buffer annotations/parentheses until completion. A streaming note
        // must not leak its first clause before it can be classified.
        final remainder = text.substring(_sent).trimLeft();
        if ('[`<（('.contains(text[i]) ||
            remainder.startsWith('注') ||
            remainder.startsWith('备注') ||
            remainder.startsWith('说明')) {
          _defer = true;
          break;
        }
        final length = text.substring(_sent, i + 1).runes.length;
        final clause =
            '，；;：'.contains(text[i]) && length >= (_parts == 0 ? 16 : 48);
        if ('。！？!?\n'.contains(text[i]) || clause) {
          final sentence = text.substring(_sent, i + 1).trim();
          if (sentence.isNotEmpty) {
            result.add(sentence);
            _parts++;
          }
          _sent = i + 1;
        }
      }
    }
    if (complete && _sent < text.length) {
      result.add(text.substring(_sent));
      _sent = text.length;
    }
    return result;
  }
}
