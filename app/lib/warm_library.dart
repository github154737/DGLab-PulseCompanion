import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'pulse_library.dart';
import 'venice_wave_session.dart';

/// Local UI and strength preferences. No credentials, audio, history or grants.
class WarmLibrary extends ChangeNotifier {
  WarmLibrary(this.session, {this.directory});
  final VeniceWaveSession session;
  final Directory? directory;
  String aiName = '小岚';
  bool funded = false, autoSend = true, ready = false;
  bool autoSpeak = true;
  String speechVoice = 'eve';
  double speechSpeed = 1;
  String notice = '';
  final favorites = <String>{};
  final recent = <String>[];
  static const defaultCategories = [
    '渐变呼吸',
    '脉冲点刺',
    '间歇节奏',
    '持续平稳',
    '变速交替',
    '揉捏挤压',
    '复合组合',
    '其他命名',
  ];
  static const legacyCategories = {
    '渐变': '渐变呼吸',
    '脉冲': '脉冲点刺',
    '间歇': '间歇节奏',
    '复合': '复合组合',
  };
  final categories = <String>[...defaultCategories];
  final assignments = <String, String>{};
  final tags = <String, List<String>>{};
  File? _settings;
  Directory? _dir;
  bool _disposed = false;
  Future<void> _writes = Future.value();
  String name(PulseWave wave) => wave.name
      .replaceFirst(RegExp(r'^内置'), '')
      .replaceFirst(RegExp(r'^pulse-', caseSensitive: false), '')
      .replaceFirst(RegExp(r'-[0-9]{6,}(\([0-9]+\))?$'), '');

  // Name-based organization only; not a claim about physical effect or placement.
  final _suggested = <String, String>{};
  String suggestedCategory(PulseWave wave) =>
      _suggested.putIfAbsent(wave.id, () => _classifyName(wave));
  String _classifyName(PulseWave wave) {
    final n = name(wave);
    if (RegExp(r'组合|复合|➕|\+|混合').hasMatch(n)) return '复合组合';
    if (RegExp(r'间歇|间断|断续|缺口|停顿').hasMatch(n)) return '间歇节奏';
    if (RegExp(r'变速|交替|快慢|高低|乱|随机').hasMatch(n)) return '变速交替';
    if (RegExp(r'揉|捏|挤压|按摩').hasMatch(n)) return '揉捏挤压';
    if (RegExp(r'呼吸|渐|缓|爬坡|阶梯|起伏|潮汐|平滑').hasMatch(n)) return '渐变呼吸';
    if (RegExp(r'脉冲|点刺|敲|抖|跳|刺|突然').hasMatch(n)) return '脉冲点刺';
    if (RegExp(r'持续|连续|恒|平稳|高频|低频').hasMatch(n)) return '持续平稳';
    return '其他命名';
  }

  String category(PulseWave wave) =>
      assignments[wave.id] ??
      (categories.contains(suggestedCategory(wave))
          ? suggestedCategory(wave)
          : '未分类');
  List<String> nameTags(PulseWave wave) {
    final n = name(wave);
    return <String>{
      for (final word in [
        '呼吸',
        '渐变',
        '爬坡',
        '阶梯',
        '脉冲',
        '点刺',
        '间断',
        '持续',
        '连续',
        '变速',
        '快慢',
        '随机',
        '揉捏',
        '挤压',
        '高频',
        '低频',
        '组合',
        '自定义',
      ])
        if (n.contains(word)) word,
      if (RegExp(r'乳|胸|腹|腿|阴|前列腺|环').hasMatch(n)) '部位命名',
      ...?tags[wave.id],
    }.toList();
  }

  Future<void> restore() async {
    try {
      final bytes = await rootBundle.load('assets/user-waveforms.zip');
      if (_disposed) return;
      session.add(
        importPulseFiles(
          'library.zip',
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      );
      _dir = directory ?? await getApplicationSupportDirectory();
      if (_disposed) return;
      final legacy = File('${_dir!.path}/venice-pulse-library.json');
      if (await legacy.exists() && await legacy.length() <= 24 * 1024 * 1024) {
        final rows = jsonDecode(await legacy.readAsString()) as List;
        for (final row in rows.take(1000)) {
          if (_disposed) return;
          session.add(
            importPulseFiles(
              row['name'] as String,
              base64Decode(row['bytes'] as String),
            ),
          );
        }
      }
      _settings = File('${_dir!.path}/warm-preferences-v1.json');
      if (await _settings!.exists() &&
          await _settings!.length() <= 512 * 1024) {
        final data =
            jsonDecode(await _settings!.readAsString()) as Map<String, dynamic>;
        if (_disposed) return;
        final savedName = data['aiName'];
        final limits = data['strengthLimits'];
        if (limits is Map &&
            limits['cap'] is int &&
            limits['maxIncrease'] is int &&
            limits['manualStep'] is int) {
          session.setLimits(
            cap: limits['cap'] as int,
            maxIncrease: limits['maxIncrease'] as int,
            manualStep: limits['manualStep'] as int,
          );
        }
        if (savedName is String && validName(savedName)) aiName = savedName;
        funded = data['funded'] == true;
        autoSend = data['autoSend'] != false;
        autoSpeak = data['autoSpeak'] != false;
        if (const ['eve', 'ara', 'rex', 'sal'].contains(data['speechVoice'])) {
          speechVoice = data['speechVoice'] as String;
        }
        final speed = data['speechSpeed'];
        if (speed is num && speed.isFinite && speed >= .7 && speed <= 1.5) {
          speechSpeed = speed.toDouble();
        }
        final known = session.waves.map((w) => w.id).toSet();
        List<String> strings(Object? value) =>
            value is List ? value.whereType<String>().toList() : [];
        favorites.addAll(strings(data['favorites']).where(known.contains));
        recent.addAll(strings(data['recent']).where(known.contains).take(50));
        if (data['categories'] is List) {
          categories
            ..clear()
            ..addAll((data['version'] == 2) ? <String>[] : defaultCategories)
            ..addAll(
              strings(data['categories'])
                  .map((c) => legacyCategories[c] ?? c)
                  .where((c) => validCategory(c) && !categories.contains(c))
                  .toSet()
                  .take(100),
            );
        }
        if (data['assignments'] is Map) {
          for (final e in (data['assignments'] as Map).entries) {
            if (known.contains(e.key) &&
                (categories.contains(legacyCategories[e.value] ?? e.value) ||
                    e.value == '未分类')) {
              assignments[e.key as String] =
                  legacyCategories[e.value] ?? e.value as String;
            }
          }
        }
        if (data['tags'] is Map) {
          for (final e in (data['tags'] as Map).entries) {
            if (known.contains(e.key)) {
              tags[e.key as String] = strings(e.value)
                  .where(validCategory)
                  .take(6)
                  .toList();
            }
          }
        }
        final candidates = strings(data['candidates'])
            .where(known.contains)
            .take(24)
            .toSet();
        if (data['candidates'] is List) {
          session.candidates
            ..clear()
            ..addAll(candidates);
        }
      }
    } catch (_) {
      notice = '部分本机设置未恢复，可继续使用或重新导入波形。';
    } finally {
      if (!session.active) session.receipt = '尚未授权输出';
      ready = true;
      if (!_disposed) notifyListeners();
    }
  }

  static bool validName(String name) =>
      name.trim().isNotEmpty &&
      name.runes.length <= 20 &&
      !RegExp(r'[\x00-\x1F\x7F]').hasMatch(name);
  static bool validCategory(String value) =>
      value.trim().isNotEmpty &&
      value.runes.length <= 16 &&
      value != '未分类' &&
      !RegExp(r'[\x00-\x1F\x7F]').hasMatch(value);

  Future<void> save() {
    final data = jsonEncode({
      'version': 2,
      'aiName': aiName,
      'funded': funded,
      'autoSend': autoSend,
      'autoSpeak': autoSpeak,
      'speechVoice': speechVoice,
      'speechSpeed': speechSpeed,
      'strengthLimits': {
        'cap': session.cap,
        'maxIncrease': session.maxIncrease,
        'manualStep': session.manualStep,
      },
      'favorites': favorites.toList(),
      'recent': recent,
      'categories': categories,
      'assignments': assignments,
      'tags': tags,
      'candidates': session.candidates.toList(),
    });
    _writes = _writes.then((_) async {
      try {
        _dir ??= directory ?? await getApplicationSupportDirectory();
        _settings ??= File('${_dir!.path}/warm-preferences-v1.json');
        await _dir!.create(recursive: true);
        final pending = File('${_settings!.path}.pending');
        await pending.writeAsString(data, flush: true);
        await pending.rename(_settings!.path);
        if (notice == '设置保存失败，本次修改仅在当前运行期间有效。') {
          notice = '';
        }
      } catch (_) {
        notice = '设置保存失败，本次修改仅在当前运行期间有效。';
      }
    });
    if (!_disposed) notifyListeners();
    return _writes;
  }

  Future<void> importBytes(String filename, List<int> bytes) async {
    final result = importPulseFiles(filename, bytes);
    session.add(result);
    notice = session.receipt;
    try {
      _dir ??= directory ?? await getApplicationSupportDirectory();
      await _dir!.create(recursive: true);
      final file = File('${_dir!.path}/venice-pulse-library.json');
      final pending = File('${file.path}.pending');
      await pending.writeAsString(
        jsonEncode(
          session.waves
              .where((w) => !w.deviceReady)
              .map(
                (w) => {
                  'name': '${w.name}.pulse',
                  'bytes': base64Encode(w.bytes),
                },
              )
              .toList(),
        ),
        flush: true,
      );
      await pending.rename(file.path);
    } catch (_) {
      notice += '；保存失败，下次需重新导入';
    }
    if (!_disposed) notifyListeners();
  }

  void markRecent(String id) {
    recent
      ..remove(id)
      ..insert(0, id);
    if (recent.length > 50) recent.removeRange(50, recent.length);
    save();
  }

  void toggleFavorite(String id) {
    if (!favorites.add(id)) favorites.remove(id);
    save();
  }

  void renameCategory(String old, String next) {
    if (!validCategory(next) || categories.contains(next)) return;
    final index = categories.indexOf(old);
    if (index < 0) return;
    categories[index] = next;
    assignments.updateAll((id, category) => category == old ? next : category);
    // Built-in classifications must follow the renamed category too.
    for (final w in session.waves) {
      if (!assignments.containsKey(w.id)) {
        final fallback = suggestedCategory(w);
        if (fallback == old) assignments[w.id] = next;
      }
    }
    save();
  }

  void removeCategory(String category) {
    for (final w in session.waves) {
      if (this.category(w) == category) assignments[w.id] = '未分类';
    }
    categories.remove(category);
    save();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
