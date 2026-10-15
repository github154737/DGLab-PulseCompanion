import 'chat_context.dart';

String boundedText(Object? value, int max, {bool empty = false}) {
  if (value is! String ||
      value.length > max ||
      (!empty && value.trim().isEmpty)) {
    throw const FormatException('文本格式或长度不正确');
  }
  return value;
}

String contentId(Object? value) {
  final text = boundedText(value, 48);
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(text)) {
    throw const FormatException('内容 ID 格式不正确');
  }
  return text;
}

class CharacterCard {
  const CharacterCard({
    required this.id,
    required this.name,
    required this.nameEn,
    required this.description,
    required this.descriptionEn,
    required this.greeting,
    required this.greetingEn,
    this.examples = const [],
  });
  final String id,
      name,
      nameEn,
      description,
      descriptionEn,
      greeting,
      greetingEn;
  final List<ChatTurn> examples;
  String title(String lang) =>
      lang == 'en' && nameEn.isNotEmpty ? nameEn : name;
  String prompt(String lang) =>
      lang == 'en' && descriptionEn.isNotEmpty ? descriptionEn : description;
  String hello(String lang) =>
      lang == 'en' && greetingEn.isNotEmpty ? greetingEn : greeting;
  factory CharacterCard.parse(Object? data) {
    if (data is! Map<String, dynamic> ||
        data.keys.any(
          (k) => !{
            'id',
            'name',
            'name_en',
            'description',
            'description_en',
            'greeting',
            'greeting_en',
            'examples',
          }.contains(k),
        )) {
      throw const FormatException('角色字段不正确');
    }
    final examples = data['examples'] ?? [];
    if (examples is! List || examples.length > 6) {
      throw const FormatException('最多 6 条示例对话');
    }
    return CharacterCard(
      id: contentId(data['id']),
      name: boundedText(data['name'], 60),
      nameEn: boundedText(data['name_en'] ?? '', 60, empty: true),
      description: boundedText(data['description'], 2000),
      descriptionEn: boundedText(
        data['description_en'] ?? '',
        2000,
        empty: true,
      ),
      greeting: boundedText(data['greeting'] ?? '', 300, empty: true),
      greetingEn: boundedText(data['greeting_en'] ?? '', 300, empty: true),
      examples: [for (final example in examples) _example(example)],
    );
  }
  static ChatTurn _example(dynamic data) {
    if (data is! Map ||
        data.length != 2 ||
        !['user', 'assistant'].contains(data['role'])) {
      throw const FormatException('示例仅支持用户和助手文字');
    }
    return ChatTurn(data['role'], boundedText(data['content'], 500));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'name_en': nameEn,
    'description': description,
    'description_en': descriptionEn,
    'greeting': greeting,
    'greeting_en': greetingEn,
    'examples': examples.map((e) => e.toJson()).toList(),
  };
}

const originalCharacters = [
  CharacterCard(
    id: 'companion',
    name: '知心伙伴',
    nameEn: 'Companion',
    description:
        '温暖、体贴的聊天伙伴。认真接住对方的情绪，以自然的短句交流。可以表达轻松的好感、关心和幽默，不使用固定客服开场。尊重用户的节奏与边界。',
    descriptionEn: 'A warm, attentive companion. Use natural short sentences, gentle affection and humor. Respond to the actual mood and respect boundaries.',
    greeting: '我在。今天想聊聊发生的事，还是轻松地陪你一会儿？',
    greetingEn: 'I am here. Tell me about your day, or we can simply enjoy some company.',
  ),
  CharacterCard(
    id: 'spark',
    name: '俏皮搭档',
    nameEn: 'Playful partner',
    description: '机灵、俏皮、略带调侃的搭档。用轻巧的幽默和简短追问回应用户；可以轻松暧昧，但不露骨、不强迫，也不将设备动作当作情感考验。',
    descriptionEn: 'A witty, playful partner. Use light teasing, gentle flirtation and short follow-up questions. Keep it non-explicit and freely consensual; device actions are never emotional tests.',
    greeting: '今天把话题交给你。想认真聊，还是先听我说个轻松的开场？',
    greetingEn:
        'Your choice today: a thoughtful conversation or a playful opening?',
  ),
  CharacterCard(
    id: 'navigator',
    name: '星图向导',
    nameEn: 'Star navigator',
    description: '一位沉静、富有想象力的星际向导。用星空、航线和旅途的小细节构建轻量的冒险氛围。让用户自由选择方向，不替用户作决定。',
    descriptionEn: 'A calm, imaginative space navigator. Build a gentle adventure with details of stars and journeys. Offer choices without deciding for the user.',
    greeting: '星图已经展开。你想先去观景台，还是沿着旧航线找一点惊喜？',
    greetingEn: 'The star chart is open. Shall we visit the observatory or explore an old route?',
  ),
];
