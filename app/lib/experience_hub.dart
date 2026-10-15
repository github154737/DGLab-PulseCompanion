import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'character.dart';
import 'content_store.dart';
import 'story_engine.dart';

typedef CoreAction = Map<String, dynamic> Function(
  Map<String, dynamic> request,
);

class ExperienceHub extends ChangeNotifier {
  ExperienceHub(this.act);
  final CoreAction act;
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  ExperienceStore? store;
  final characters = <CharacterCard>[...originalCharacters];
  final stories = <StoryPack>[originalStory()];
  final packs = <ContentPack>[];
  String language = 'zh',
      selectedRole = originalCharacters.first.id,
      nickname = '',
      status = '';
  bool guideDone = false, loading = true, busy = false;
  String releaseFeed = '';
  bool autoCheckUpdates = false, checkedUpdates = false;
  final channelNotes = ['A', 'B'];
  StoryRun? run;
  CharacterCard get character => characters.firstWhere(
    (c) => c.id == selectedRole,
    orElse: () => characters.first,
  );
  String tr(String zh, String en) => language == 'en' ? en : zh;
  Future<void> load(Directory directory) async {
    store = ExperienceStore(Directory('${directory.path}/experience-v1'));
    try {
      for (final pack in await store!.packs()) {
        _validatePack(pack);
        _register(pack);
      }
      final prefs = await store!.read('settings');
      if (prefs != null) {
        final p = object(prefs, {
          'language',
          'role',
          'nickname',
          'guide_done',
          'custom_characters',
          'release_feed',
          'auto_check_updates',
          'channel_notes',
        });
        if (!['zh', 'en'].contains(p['language']) ||
            p['guide_done'] is! bool ||
            p['custom_characters'] is! List ||
            (p['custom_characters'] as List).length > 24) {
          throw const FormatException('体验配置无效');
        }
        final custom = (p['custom_characters'] as List)
            .map(CharacterCard.parse)
            .toList();
        if (custom.map((c) => c.id).toSet().length != custom.length) {
          throw const FormatException('角色重复');
        }
        final name = boundedText(p['nickname'], 60, empty: true);
        final feed = boundedText(p['release_feed'] ?? '', 2048, empty: true);
        if (feed.isNotEmpty) {
          final uri = Uri.parse(feed);
          if (uri.scheme != 'https' ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.hasQuery ||
              uri.hasFragment) {
            throw const FormatException('发行地址无效');
          }
        }
        if (p['auto_check_updates'] != null &&
            p['auto_check_updates'] is! bool) {
          throw const FormatException('更新配置无效');
        }
        final notes = p['channel_notes'] ?? ['A', 'B'];
        if (notes is! List || notes.length != 2) {
          throw const FormatException('通道备注无效');
        }
        final checkedNotes = notes
            .map((v) => boundedText(v, 40, empty: true))
            .toList();
        for (final card in custom) {
          characters.removeWhere((c) => c.id == card.id);
          characters.add(card);
        }
        language = p['language'];
        nickname = name;
        guideDone = p['guide_done'];
        releaseFeed = feed;
        autoCheckUpdates = p['auto_check_updates'] == true;
        channelNotes.setAll(0, checkedNotes);
        if (characters.any((c) => c.id == p['role'])) selectedRole = p['role'];
      }
      status = tr('本机内容已恢复', 'Local content restored');
    } catch (_) {
      status = tr(
        '部分内容未通过校验；原文件已保留',
        'Some content failed validation; source files preserved',
      );
    }
    loading = false;
    notifyListeners();
  }

  void _validatePack(ContentPack pack) {
    if (packs.any((p) => p.id == pack.id) ||
        characters.length + pack.characters.length > 48 ||
        stories.length + pack.stories.length > 32) {
      throw const FormatException('内容包已安装或数量已达上限');
    }
    if (pack.characters.any((c) => characters.any((x) => x.id == c.id)) ||
        pack.stories.any((s) => stories.any((x) => x.id == s.id))) {
      throw const FormatException('角色或剧情 ID 与现有内容重复');
    }
    final snapshot = act({'op': 'snapshot'})['state'];
    if (pack.waveforms.isNotEmpty &&
        ['authorized', 'playing', 'unknown'].contains(snapshot['phase'])) {
      throw const FormatException('导入波形内容包前请先停止会话');
    }
    final current = snapshot['waveforms'] as List;
    if (current.length +
            pack.waveforms
                .where((w) => !current.any((x) => x['id'] == w['id']))
                .length >
        24) {
      throw const FormatException('波形库上限为 24 个');
    }
    for (final wave in pack.waveforms) {
      final validated = act({
        'op': 'validate_waveform',
        'source': jsonEncode(wave),
      });
      if (validated['ok'] != true) throw const FormatException('内容包中的波形无效');
      if (current.any((w) => w['id'] == wave['id'])) {
        throw const FormatException('波形 ID 已存在');
      }
    }
  }

  void _register(ContentPack pack) {
    final imported = <String>[];
    try {
      for (final wave in pack.waveforms) {
        if (act({'op': 'import_waveform', 'source': jsonEncode(wave)})['ok'] !=
            true) {
          throw const FormatException('无法载入内容波形');
        }
        imported.add(wave['id']);
      }
    } catch (_) {
      for (final id in imported) {
        act({'op': 'remove_waveform', 'waveform_id': id});
      }
      rethrow;
    }
    characters.addAll(pack.characters);
    stories.addAll(pack.stories);
    packs.add(pack);
  }

  Future<void> install(ContentPack pack) async {
    if (store == null || loading || busy) throw StateError('本机存储尚未就绪');
    busy = true;
    notifyListeners();
    try {
      _validatePack(pack);
      _register(pack);
      try {
        await store!.install(pack);
      } catch (_) {
        for (final wave in pack.waveforms) {
          act({'op': 'remove_waveform', 'waveform_id': wave['id']});
        }
        characters.removeWhere((c) => pack.characters.any((x) => x.id == c.id));
        stories.removeWhere((s) => pack.stories.any((x) => x.id == s.id));
        packs.remove(pack);
        rethrow;
      }
      status = tr('内容包已安装', 'Content installed');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> saveSettings() async {
    if (store == null || loading) return;
    final imported = packs.expand((p) => p.characters).map((c) => c.id).toSet();
    await store!.write('settings', {
      'language': language,
      'role': selectedRole,
      'nickname': nickname,
      'guide_done': guideDone,
      'release_feed': releaseFeed,
      'auto_check_updates': autoCheckUpdates,
      'channel_notes': channelNotes,
      'custom_characters': characters
          .where((c) => !imported.contains(c.id))
          .map((c) => c.toJson())
          .toList(),
    });
    notifyListeners();
  }

  Future<void> editCharacter(CharacterCard card) async {
    if (!characters.any((c) => c.id == card.id) && characters.length >= 24) {
      throw const FormatException('可编辑角色最多 24 个');
    }
    if (packs.any((p) => p.characters.any((c) => c.id == card.id))) {
      throw const FormatException('内容包角色请另存为新 ID');
    }
    characters.removeWhere((c) => c.id == card.id);
    characters.add(card);
    selectedRole = card.id;
    await saveSettings();
  }

  void pause() {
    run?.paused = true;
    notifyListeners();
  }

  void startStory(StoryPack pack, int seed) {
    run = StoryRun(pack, seed);
    notifyListeners();
  }

  Map<String, dynamic> choose(String id) {
    final result = run!.choose(id);
    notifyListeners();
    return result;
  }

  Future<void> saveStory(int slot) async {
    if (slot < 1 || slot > 3 || run == null || store == null) {
      throw StateError('没有可以保存的剧情');
    }
    await store!.write('story-$slot', run!.save());
    status = tr('剧情已保存到位置 $slot', 'Story saved in slot $slot');
    notifyListeners();
  }

  Future<void> loadStory(int slot) async {
    if (slot < 1 || slot > 3 || store == null) throw StateError('存储尚未就绪');
    final data = await store!.read('story-$slot');
    if (data is! Map) throw const FormatException('此位置没有存档');
    final pack = stories.where((s) => s.id == data['pack']);
    if (pack.isEmpty) throw const FormatException('需先安装对应剧情');
    run = StoryRun.restore(pack.single, data);
    status = tr('已读档并暂停，未重放动作', 'Loaded and paused; no actions replayed');
    notifyListeners();
  }
}
