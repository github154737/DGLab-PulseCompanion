import 'dart:convert';

import 'chat_context.dart';
import 'control_execution.dart';

/// Ephemeral conversation data, never a replacement for local authorization.
class ControlConversation {
  ControlConversation({DateTime Function()? now}) : now = now ?? DateTime.now;
  final DateTime Function() now;
  ControlExecution? lastExecution, lastApplied;
  Map<String, dynamic>? _proposal, _proposalState;
  DateTime? _proposalTime;

  void record(ControlExecution execution) {
    lastExecution = execution;
    if (execution.applied && execution.changed) lastApplied = execution;
  }

  void clear() {
    lastExecution = lastApplied = null;
    clearProposal();
  }

  void clearProposal() {
    _proposal = _proposalState = null;
    _proposalTime = null;
  }

  static bool isConfirmation(String text) => RegExp(
    r'^(可以|好|好的|行|同意|确认|就这样|按你说的|可以就这样|yes|ok)[。！! .]*$',
    caseSensitive: false,
  ).hasMatch(text.trim());

  Map<String, dynamic>? proposal(Map<String, dynamic> state) {
    if (_proposal == null) return null;
    if (now().difference(_proposalTime!) > const Duration(minutes: 2) ||
        jsonEncode(state) != jsonEncode(_proposalState) ||
        state['authorized'] != true) {
      clearProposal();
    }
    return _proposal == null ? null : Map.of(_proposal!);
  }

  /// Only a single, explicit numeric/waveform proposal is eligible for a bare "yes".
  /// General suggestions and model prose never become executable commands.
  void rememberProposal(
    String reply,
    ControlExecution execution,
    Map<String, dynamic> state,
  ) {
    clearProposal();
    if (execution.status != 'held' ||
        !execution.matches(state) ||
        state['authorized'] != true) {
      return;
    }
    final match = RegExp(
      r'^(?:要不要|是否|可以)?\s*([ABab])\s*(?:通道)?\s*(?:调到|设为|设置为)\s*(\d{1,2})\s*(?:可以吗|好吗|吗)?[？?]$',
    ).firstMatch(reply.trim());
    if (match != null) {
      final channel = match[1]!.toLowerCase();
      final value = int.parse(match[2]!);
      if (value > (state['cap'] as int) ||
          value - (state[channel] as int) >
              (state['max_increase_per_turn'] as int)) {
        return;
      }
      _proposal = {
        'action': 'set',
        'a': state['a'],
        'b': state['b'],
        'waveform_id': state['selected'],
        channel: value,
      };
    } else {
      final waveform = RegExp(
        r'^(?:要不要|是否|可以)?\s*(?:换成|切换到|选择)\s*(.+?)(?:可以吗|好吗|吗)?[？?]$',
      ).firstMatch(reply.trim());
      if (waveform == null) return;
      final options = (state['waveforms'] as List)
          .where((w) => w['name'] == waveform[1]!.trim())
          .toList();
      if (options.length != 1) return;
      _proposal = {
        'action': 'set',
        'a': state['a'],
        'b': state['b'],
        'waveform_id': options.single['id'],
      };
    }
    _proposalState = jsonDecode(jsonEncode(state)) as Map<String, dynamic>;
    _proposalTime = now();
  }

  Map<String, dynamic> data(
    Map<String, dynamic> state,
    List<ChatTurn> history,
  ) => {
    'recent_turns': history
        .skip((history.length - 8).clamp(0, history.length))
        .where((t) => t.role == 'user' || t.role == 'assistant')
        .map(
          (t) => {
            'role': t.role,
            'content': t.text.substring(0, t.text.length.clamp(0, 800)),
          },
        )
        .toList(),
    'last_execution': lastExecution?.toJson(),
    'last_applied_action': lastApplied?.toJson(),
    'pending_confirmation': proposal(state),
  };

  String plannerInput(
    String text,
    Map<String, dynamic> state,
    List<ChatTurn> history,
  ) => jsonEncode({
    'user_message': text,
    'local_state': state,
    'conversation': data(state, history),
  });
}
