class ChatTurn {
  const ChatTurn(this.role, this.text);
  final String role;
  final String text;
  Map<String, String> toJson() => {'role': role, 'content': text};
}

class ChatContext {
  const ChatContext({
    this.controlAllowed = true,
    this.gain = 0.5,
    this.style = '温柔',
    this.history = const [],
    this.waveforms = const [],
    this.playing = false,
    this.remainingMs = 0,
    this.persona = '',
    this.selectedWaveform,
    this.channels = const [],
    this.patterns = const [],
    this.language = 'zh',
    this.observation = '',
    this.executionReceipt = '',
    this.replyGuidance = '',
    this.character = '',
    this.aiName = '',
    this.nickname = '',
    this.examples = const [],
    this.imageData,
    this.simulationOnly = true,
  });
  final bool controlAllowed;
  final double gain;
  final String style;
  final List<ChatTurn> history;
  final List<String> waveforms;
  final bool playing;
  final int remainingMs;
  final String persona;
  final String? selectedWaveform;
  final List<Map<String, dynamic>> channels;
  final List<String> patterns;
  final String language, observation;
  final String executionReceipt;

  /// Validated model advice, never an execution receipt or device permission.
  final String replyGuidance;
  final String character, nickname;
  final String aiName;
  final List<ChatTurn> examples;
  final String? imageData;
  final bool simulationOnly;
}

class ChatMessage {
  ChatMessage({required this.user, required this.text, this.receipt});
  final bool user;
  String text;
  final String? receipt;
}
