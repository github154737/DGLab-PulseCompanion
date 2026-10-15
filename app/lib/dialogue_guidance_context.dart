import 'dart:convert';

import 'chat_context.dart';

const _maxHistoryMessages = 24;
const _maxMessageCharacters = 600;
const _maxInputCharacters = 20000;
const _truncationMarker = '\n[中间内容已截断]\n';

/// Bounded dialogue data for the optional guidance planner. No device state,
/// execution receipt, or authorization is inferred from conversation history.
String buildDialogueGuidanceInput(String text, List<ChatTurn> history) {
  if (text.length > 2000) {
    // Never include the user's message in diagnostic errors.
    throw ArgumentError('对话导答当前消息不能超过 2000 字符');
  }
  final conversational = history
      .where((turn) => turn.role == 'user' || turn.role == 'assistant')
      .toList();
  final first = (conversational.length - _maxHistoryMessages).clamp(
    0,
    conversational.length,
  );
  final recent = conversational.skip(first).map(_GuidanceTurn.new).toList();
  var omitted = first;

  String encode() => jsonEncode({
    'user_message': text,
    'conversation': {
      'recent_turns': recent
          .map((turn) => {'role': turn.role, 'content': turn.content})
          .toList(),
    },
    'context_truncation': {
      'history_truncated': omitted > 0,
      'omitted_history_messages': omitted,
      'filtered_non_conversation_messages':
          history.length - conversational.length,
      'messages_truncated': recent.any((turn) => turn.truncated),
      // These zero-based indices refer to the retained recent_turns list.
      'truncated_message_indices': [
        for (var i = 0; i < recent.length; i++)
          if (recent[i].truncated) i,
      ],
    },
  });

  var encoded = encode();
  // Measure the actual encoded JSON: quotes, control characters, and escaped
  // backslashes can expand far beyond the source character count.
  while (encoded.length > _maxInputCharacters && recent.isNotEmpty) {
    recent.removeAt(0);
    omitted++;
    encoded = encode();
  }
  // A <=2000-character current message fits even at maximum JSON escaping.
  if (encoded.length > _maxInputCharacters) {
    throw StateError('对话导答输入超过长度限制');
  }
  return encoded;
}

class _GuidanceTurn {
  _GuidanceTurn(ChatTurn turn)
    : role = turn.role,
      content = _boundedMessage(turn.text),
      truncated = turn.text.length > _maxMessageCharacters;

  final String role;
  final String content;
  final bool truncated;
}

String _boundedMessage(String text) {
  if (text.length <= _maxMessageCharacters) return text;
  final available = _maxMessageCharacters - _truncationMarker.length;
  var headEnd = available ~/ 2;
  var tailStart = text.length - (available - headEnd);
  // Keep complete UTF-16 pairs when a boundary lands inside an emoji.
  if (_splitsSurrogatePair(text, headEnd)) headEnd--;
  if (_splitsSurrogatePair(text, tailStart)) tailStart++;
  return '${text.substring(0, headEnd)}$_truncationMarker${text.substring(tailStart)}';
}

bool _splitsSurrogatePair(String text, int boundary) =>
    boundary > 0 &&
    boundary < text.length &&
    (text.codeUnitAt(boundary - 1) & 0xfc00) == 0xd800 &&
    (text.codeUnitAt(boundary) & 0xfc00) == 0xdc00;
