import 'dart:convert';

import 'character.dart';

const storyStats = ['energy', 'courage', 'focus', 'trust'];
Map<String, dynamic> object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.keys.any((k) => !keys.contains(k))) {
    throw const FormatException('内容包含不支持的字段');
  }
  return value;
}

int integer(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('数值超出范围');
  }
  return value;
}

String bilingual(Map data, String key, String lang) =>
    lang == 'en' && (data['${key}_en'] as String? ?? '').isNotEmpty
    ? data['${key}_en']
    : data[key] as String;

class StoryPack {
  StoryPack._(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'];
  List<Map<String, dynamic>> get rooms =>
      (data['rooms'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> room(String id) =>
      rooms.singleWhere((r) => r['id'] == id);
  String title(String lang) => bilingual(data, 'title', lang);
  factory StoryPack.parse(Object? value) {
    final p = object(value, {'id', 'title', 'title_en', 'start', 'rooms'});
    contentId(p['id']);
    boundedText(p['title'], 80);
    boundedText(p['title_en'] ?? '', 80, empty: true);
    contentId(p['start']);
    if (p['rooms'] is! List ||
        (p['rooms'] as List).isEmpty ||
        (p['rooms'] as List).length > 80) {
      throw const FormatException('剧情需要 1–80 个节点');
    }
    final ids = <String>{};
    for (final raw in p['rooms']) {
      final r = object(raw, {
        'id',
        'title',
        'title_en',
        'text',
        'text_en',
        'choices',
        'ending',
        'pattern',
        'variants',
      });
      if (!ids.add(contentId(r['id']))) {
        throw const FormatException('剧情节点 ID 重复');
      }
      boundedText(r['title'], 80);
      boundedText(r['title_en'] ?? '', 80, empty: true);
      boundedText(r['text'], 3000);
      boundedText(r['text_en'] ?? '', 3000, empty: true);
      if (r['ending'] != null && r['ending'] is! bool) {
        throw const FormatException('结局字段不正确');
      }
      if (r['pattern'] != null && !contentId(r['pattern']).startsWith('lab_')) {
        throw const FormatException('剧情反馈只支持内置波形');
      }
      if (r['choices'] is! List || (r['choices'] as List).length > 8) {
        throw const FormatException('节点最多 8 个选项');
      }
      if (r['ending'] != true && (r['choices'] as List).isEmpty) {
        throw const FormatException('普通节点需要选项');
      }
      if (r['ending'] == true && (r['choices'] as List).isNotEmpty) {
        throw const FormatException('结局不能有未执行的跳转');
      }
      final variants = r['variants'] ?? [];
      if (variants is! List || variants.length > 8) {
        throw const FormatException('文本变体过多');
      }
      for (final rawVariant in variants) {
        final v = object(rawVariant, {'text', 'text_en'});
        boundedText(v['text'], 3000);
        boundedText(v['text_en'] ?? '', 3000, empty: true);
      }
      final choices = <String>{};
      for (final rawChoice in r['choices']) {
        final c = object(rawChoice, {
          'id',
          'label',
          'label_en',
          'next',
          'requires',
          'check',
          'fail_next',
          'effects',
        });
        if (!choices.add(contentId(c['id']))) {
          throw const FormatException('选项 ID 重复');
        }
        boundedText(c['label'], 160);
        boundedText(c['label_en'] ?? '', 160, empty: true);
        contentId(c['next']);
        if (c['fail_next'] != null) contentId(c['fail_next']);
        for (final key in ['requires', 'effects']) {
          final stats = object(
            c[key] ?? <String, dynamic>{},
            storyStats.toSet(),
          );
          for (final v in stats.values) {
            integer(v, key == 'effects' ? -10 : 0, 20);
          }
        }
        if (c['check'] != null) {
          final check = object(c['check'], {'stat', 'target', 'sides'});
          if (!storyStats.contains(check['stat'])) {
            throw const FormatException('未知检定属性');
          }
          integer(check['target'], 1, 30);
          if (![4, 6, 8].contains(check['sides'])) {
            throw const FormatException('仅支持 D4 / D6 / D8');
          }
        }
      }
    }
    if (!ids.contains(p['start'])) throw const FormatException('缺少起始节点');
    for (final r in p['rooms']) {
      for (final c in r['choices']) {
        if (!ids.contains(c['next']) ||
            c['fail_next'] != null && !ids.contains(c['fail_next'])) {
          throw const FormatException('剧情跳转目标不存在');
        }
      }
    }
    final reachable = <String>{p['start']};
    for (var i = 0; i < ids.length; i++) {
      for (final r in p['rooms']) {
        if (reachable.contains(r['id'])) {
          for (final c in r['choices']) {
            reachable.add(c['next']);
            if (c['fail_next'] != null) reachable.add(c['fail_next']);
          }
        }
      }
    }
    if (reachable.length != ids.length ||
        !(p['rooms'] as List).any((r) => r['ending'] == true)) {
      throw const FormatException('剧情包含不可达节点或缺少结局');
    }
    // Own a validated copy; imported maps cannot later mutate the runtime.
    return StoryPack._(jsonDecode(jsonEncode(p)) as Map<String, dynamic>);
  }
}

class StoryRun {
  StoryRun(this.pack, int seed)
    : seed = seed & 0x7fffffff,
      randomState = (seed & 0x7fffffff) + 1,
      roomId = pack.data['start'] {
    visits[roomId] = 1;
  }
  final StoryPack pack;
  final int seed;
  int randomState, turn = 0;
  String roomId;
  bool paused = false;
  Map<String, int> stats = {'energy': 10, 'courage': 5, 'focus': 5, 'trust': 0};
  Map<String, int> visits = {};
  List<Map<String, dynamic>> log = [];
  Map<String, dynamic> get room => pack.room(roomId);
  bool get ended => room['ending'] == true;
  List<String> unmet(Map choice) => [
    for (final entry in (choice['requires'] as Map? ?? {}).entries)
      if (stats[entry.key]! < entry.value)
        '${entry.key} ≥ ${entry.value} (${stats[entry.key]})',
  ];
  int roll(int sides) {
    randomState = (randomState * 1664525 + 1013904223) & 0xffffffff;
    return randomState % sides + 1;
  }

  String narrative(String lang) {
    final variants = room['variants'] as List? ?? [];
    final index = (seed + turn + (visits[roomId] ?? 1)) % (variants.length + 1);
    return bilingual(index == 0 ? room : variants[index - 1], 'text', lang);
  }

  Map<String, dynamic> choose(String choiceId) {
    if (paused || ended) throw StateError('剧情已暂停或结束');
    final list = (room['choices'] as List).where((c) => c['id'] == choiceId);
    if (list.length != 1) throw const FormatException('选项不存在');
    final c = list.single as Map<String, dynamic>;
    if (unmet(c).isNotEmpty) throw StateError('尚未满足选项条件');
    if (turn >= 500) throw StateError('本局已达 500 步上限，请重新开始');
    final from = roomId;
    Map<String, dynamic>? checkResult;
    var success = true;
    if (c['check'] case final Map check) {
      final dice = roll(check['sides']);
      final total = stats[check['stat']]! + dice;
      success = total >= check['target'];
      checkResult = {
        'roll': dice,
        'total': total,
        'target': check['target'],
        'success': success,
      };
    }
    if (success) {
      for (final entry in (c['effects'] as Map? ?? {}).entries) {
        stats[entry.key] = (stats[entry.key]! + (entry.value as int)).clamp(
          0,
          20,
        );
      }
    }
    roomId = success ? c['next'] : c['fail_next'] ?? from;
    turn++;
    visits[roomId] = (visits[roomId] ?? 0) + 1;
    final result = <String, dynamic>{
      'turn': turn,
      'from': from,
      'to': roomId,
      'choice': choiceId,
      'success': success,
      'check': checkResult,
    };
    log.add(result);
    if (log.length > 100) log.removeAt(0);
    return result;
  }

  Map<String, dynamic> save() => {
    'format': 'haptics_story_save_v1',
    'pack': pack.id,
    'definition': pack.data,
    'seed': seed,
    'random': randomState,
    'room': roomId,
    'turn': turn,
    'stats': stats,
    'visits': visits,
    'log': log,
  };
  static StoryRun restore(StoryPack pack, Object? value) {
    final data = object(value, {
      'format',
      'pack',
      'definition',
      'seed',
      'random',
      'room',
      'turn',
      'stats',
      'visits',
      'log',
    });
    if (data['format'] != 'haptics_story_save_v1' ||
        data['pack'] != pack.id ||
        jsonEncode(data['definition']) != jsonEncode(pack.data)) {
      throw const FormatException('存档与当前剧情版本不一致');
    }
    final run = StoryRun(pack, integer(data['seed'], 0, 0x7fffffff));
    run.randomState = integer(data['random'], 0, 0xffffffff);
    run.turn = integer(data['turn'], 0, 500);
    run.roomId = contentId(data['room']);
    pack.room(run.roomId);
    final stats = object(data['stats'], storyStats.toSet());
    if (stats.length != storyStats.length) {
      throw const FormatException('存档属性缺失');
    }
    run.stats = {
      for (final entry in stats.entries) entry.key: integer(entry.value, 0, 20),
    };
    if (data['visits'] is! Map ||
        (data['visits'] as Map).length > pack.rooms.length) {
      throw const FormatException('存档地图无效');
    }
    run.visits = {};
    for (final entry in (data['visits'] as Map).entries) {
      pack.room(contentId(entry.key));
      run.visits[entry.key] = integer(entry.value, 1, 501);
    }
    if (!run.visits.containsKey(run.roomId)) {
      throw const FormatException('存档当前位置无效');
    }
    if (data['log'] is! List || (data['log'] as List).length > 100) {
      throw const FormatException('存档日志无效');
    }
    run.log = [];
    for (final raw in data['log']) {
      final entry = object(raw, {
        'turn',
        'from',
        'to',
        'choice',
        'success',
        'check',
      });
      integer(entry['turn'], 1, 500);
      pack.room(contentId(entry['from']));
      pack.room(contentId(entry['to']));
      contentId(entry['choice']);
      if (entry['success'] is! bool) throw const FormatException('存档结果无效');
      if (entry['check'] != null) {
        final check = object(entry['check'], {
          'roll',
          'total',
          'target',
          'success',
        });
        integer(check['roll'], 1, 8);
        integer(check['total'], 1, 28);
        integer(check['target'], 1, 30);
        if (check['success'] is! bool) throw const FormatException('存档检定无效');
      }
      run.log.add(entry);
    }
    run.paused =
        true; // Restoring is read-only: no feedback or autonomous continuation.
    return run;
  }
}

StoryPack originalStory() => StoryPack.parse({
  'id': 'starlight_station',
  'title': '星光驿站',
  'title_en': 'Starlight Station',
  'start': 'arrival',
  'rooms': [
    {
      'id': 'arrival',
      'title': '抵达',
      'title_en': 'Arrival',
      'text': '雨停了，驿站的灯亮起来。向导递来一张星图，等你选择今晚的路线。',
      'text_en': 'The rain has stopped. Your guide unfolds a star chart and waits for you to choose tonight’s route.',
      'choices': [
        {
          'id': 'garden',
          'label': '去温室看看',
          'label_en': 'Visit the greenhouse',
          'next': 'garden',
          'effects': {'trust': 1},
        },
        {
          'id': 'tower',
          'label': '登上观测塔',
          'label_en': 'Climb the observatory',
          'next': 'tower',
        },
      ],
    },
    {
      'id': 'garden',
      'title': '温室',
      'title_en': 'Greenhouse',
      'text': '树叶上留着细小的水珠。你们并肩走过一段安静的小路，桌上有一壶温热的茶。',
      'text_en': 'Water glints on the leaves. You walk together along a quiet path toward a pot of warm tea.',
      'pattern': 'lab_breathe',
      'choices': [
        {
          'id': 'rest',
          'label': '休息片刻，再去观测塔',
          'label_en': 'Rest, then visit the tower',
          'next': 'tower',
          'effects': {'energy': 2, 'focus': 1},
        },
        {
          'id': 'stay',
          'label': '今晚就留在这里',
          'label_en': 'Stay here for the evening',
          'next': 'quiet_end',
        },
      ],
    },
    {
      'id': 'tower',
      'title': '观测塔',
      'title_en': 'Observatory',
      'text': '旧望远镜旁有一道需要对齐的刻度。你可以尝试找出北方的星，也可以沿原路慢慢返回。',
      'text_en': 'An old telescope needs alignment. You can try to find the northern star, or take your time walking back.',
      'choices': [
        {
          'id': 'align',
          'label': '尝试校准星图',
          'label_en': 'Align the star chart',
          'next': 'bright_end',
          'fail_next': 'garden',
          'check': {'stat': 'focus', 'target': 9, 'sides': 6},
          'effects': {'courage': 1, 'trust': 1},
        },
        {
          'id': 'return',
          'label': '一起回到温室',
          'label_en': 'Return to the greenhouse together',
          'next': 'garden',
        },
      ],
    },
    {
      'id': 'quiet_end',
      'title': '安静的夜晚',
      'title_en': 'A quiet evening',
      'text': '茶的热气慢慢散开。这一次旅行以安静的陪伴结束。',
      'text_en': 'The steam rises from your tea. This journey ends with quiet companionship.',
      'ending': true,
      'choices': [],
    },
    {
      'id': 'bright_end',
      'title': '找到星光',
      'title_en': 'Finding starlight',
      'text': '北方的星出现在镜头里。你们记下这条航线，约定下次再出发。',
      'text_en': 'The northern star comes into focus. You mark the route and agree to explore again another day.',
      'ending': true,
      'choices': [],
    },
  ],
});
