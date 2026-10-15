import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart'
    show ZipEncoder, Archive, ArchiveFile, getCrc32;

import 'character.dart';
import 'story_engine.dart';

const contentLimit = 524288;

class ContentPack {
  ContentPack._(
    this.id,
    this.name,
    this.characters,
    this.stories,
    this.waveforms,
  );
  final String id, name;
  final List<CharacterCard> characters;
  final List<StoryPack> stories;
  final List<Map<String, dynamic>> waveforms;
  factory ContentPack.parse(Object? raw) {
    final p = object(raw, {
      'format',
      'id',
      'name',
      'characters',
      'stories',
      'waveforms',
    });
    if (p['format'] != 'haptics_content_v1') {
      throw const FormatException('不支持的内容包格式');
    }
    final id = contentId(p['id']), name = boundedText(p['name'], 80);
    for (final key in ['characters', 'stories', 'waveforms']) {
      if (p[key] is! List || (p[key] as List).length > 24) {
        throw const FormatException('每类内容最多 24 项');
      }
    }
    final chars = (p['characters'] as List).map(CharacterCard.parse).toList();
    final stories = (p['stories'] as List).map(StoryPack.parse).toList();
    final waves = <Map<String, dynamic>>[];
    for (final wave in p['waveforms']) {
      if (wave is! Map<String, dynamic> ||
          utf8.encode(jsonEncode(wave)).length > 32768) {
        throw const FormatException('波形文件无效或过大');
      }
      contentId(wave['id']);
      waves.add(wave);
    }
    for (final ids in [
      chars.map((c) => c.id),
      stories.map((s) => s.id),
      waves.map((w) => w['id']),
    ]) {
      if (ids.toSet().length != ids.length) {
        throw const FormatException('内容 ID 重复');
      }
    }
    if (chars.isEmpty && stories.isEmpty && waves.isEmpty) {
      throw const FormatException('内容包为空');
    }
    return ContentPack._(id, name, chars, stories, waves);
  }
  Map<String, dynamic> toJson() => {
    'format': 'haptics_content_v1',
    'id': id,
    'name': name,
    'characters': characters.map((c) => c.toJson()).toList(),
    'stories': stories.map((s) => s.data).toList(),
    'waveforms': waveforms,
  };
  static ContentPack decode(Uint8List bytes) {
    if (bytes.length > 1048576) throw const FormatException('内容包不能超过 1 MiB');
    final json = bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b
        ? unpackContentZip(bytes)
        : bytes;
    if (json.length > contentLimit) {
      throw const FormatException('内容文本超过 512 KiB');
    }
    return ContentPack.parse(jsonDecode(utf8.decode(json)));
  }

  List<int> zip() {
    final data = utf8.encode(jsonEncode(toJson()));
    if (data.length > contentLimit) throw const FormatException('内容文本过大');
    return ZipEncoder().encode(
      Archive()..add(ArchiveFile('haptics-content.json', data.length, data)),
    );
  }
}

/// Deliberately supports a single JSON entry. No filesystem extraction, encryption,
/// ZIP64, links or archive-supplied paths. Expansion is bounded during inflation.
Uint8List unpackContentZip(Uint8List bytes) {
  Never invalid() =>
      throw const FormatException('ZIP 需仅包含 haptics-content.json，且不能加密');
  final b = ByteData.sublistView(bytes);
  int u16(int n) => n >= 0 && n + 2 <= bytes.length
      ? b.getUint16(n, Endian.little)
      : invalid();
  int u32(int n) => n >= 0 && n + 4 <= bytes.length
      ? b.getUint32(n, Endian.little)
      : invalid();
  var end = -1;
  for (var i = bytes.length - 22; i >= 0 && i >= bytes.length - 65557; i--) {
    if (u32(i) == 0x06054b50 && i + 22 + u16(i + 20) == bytes.length) {
      end = i;
      break;
    }
  }
  if (end < 0 ||
      u16(end + 4) != 0 ||
      u16(end + 6) != 0 ||
      u16(end + 8) != 1 ||
      u16(end + 10) != 1) {
    invalid();
  }
  final central = u32(end + 16), centralSize = u32(end + 12);
  if (central + centralSize != end || u32(central) != 0x02014b50) invalid();
  final flags = u16(central + 8),
      method = u16(central + 10),
      crc = u32(central + 16),
      packed = u32(central + 20),
      size = u32(central + 24);
  final nameLength = u16(central + 28),
      extra = u16(central + 30),
      comment = u16(central + 32),
      local = u32(central + 42);
  if (flags & 1 != 0 ||
      ![0, 8].contains(method) ||
      size > contentLimit ||
      packed > 1048576 ||
      central + 46 + nameLength + extra + comment != end ||
      u16(central + 34) != 0 ||
      (u32(central + 38) >> 16) & 0xf000 == 0xa000) {
    invalid();
  }
  const name = 'haptics-content.json';
  if (nameLength != name.length ||
      utf8.decode(bytes.sublist(central + 46, central + 46 + nameLength)) !=
          name ||
      u32(local) != 0x04034b50 ||
      u16(local + 6) != flags ||
      u16(local + 8) != method ||
      u16(local + 26) != nameLength) {
    invalid();
  }
  final start = local + 30 + nameLength + u16(local + 28);
  if (start + packed > central ||
      utf8.decode(bytes.sublist(local + 30, local + 30 + nameLength)) != name) {
    invalid();
  }
  final compressed = bytes.sublist(start, start + packed);
  final sink = _LimitedBytes(size);
  if (method == 0) {
    sink.add(compressed);
  } else {
    final decoder = ZLibDecoder(raw: true).startChunkedConversion(sink);
    for (var n = 0; n < compressed.length; n += 256) {
      decoder.add(compressed.sublist(n, (n + 256).clamp(0, compressed.length)));
    }
    decoder.close();
  }
  final result = sink.bytes.takeBytes();
  if (result.length != size || getCrc32(result) != crc) invalid();
  return result;
}

class _LimitedBytes implements Sink<List<int>> {
  _LimitedBytes(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('ZIP 展开超过声明大小');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}

class ExperienceStore {
  ExperienceStore(this.root);
  final Directory root;
  Future<void> _writes = Future.value();
  Future<dynamic> read(String name, {int limit = contentLimit}) async {
    final file = File('${root.path}/$name.json');
    if (!await file.exists()) return null;
    if (await file.length() > limit) throw const FormatException('保存的内容过大');
    return jsonDecode(await file.readAsString());
  }

  Future<void> write(String name, Object data) {
    final text = jsonEncode(data);
    final next = _writes.then((_) => _write(name, text));
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> _write(String name, String text) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name)) {
      throw const FormatException('无效文件名');
    }
    if (utf8.encode(text).length > contentLimit) {
      throw const FormatException('内容过大');
    }
    await root.create(recursive: true);
    final file = File('${root.path}/$name.json.pending');
    await file.writeAsString(text, flush: true);
    await file.rename('${root.path}/$name.json');
  }

  Future<List<ContentPack>> packs() async {
    final result = <ContentPack>[];
    if (!await root.exists()) return result;
    await for (final file in root.list(followLinks: false)) {
      if (file is! File ||
          !file.uri.pathSegments.last.startsWith('pack-') ||
          !file.path.endsWith('.json')) {
        continue;
      }
      if (result.length >= 16) throw const FormatException('已安装内容包超过 16 个');
      if (await file.length() > contentLimit) {
        throw const FormatException('内容包文件过大');
      }
      result.add(ContentPack.decode(await file.readAsBytes()));
    }
    return result;
  }

  Future<void> install(ContentPack pack) async {
    final file = File('${root.path}/pack-${pack.id}.json');
    if (await file.exists()) throw const FormatException('此内容包已安装');
    if ((await packs()).length >= 16) {
      throw const FormatException('最多安装 16 个内容包');
    }
    await write('pack-${pack.id}', pack.toJson());
  }
}
