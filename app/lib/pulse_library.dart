import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// Original .pulse bytes are authoritative for export. Preview timing is an
/// approximation, not a verified conversion of the official editor semantics.
class PulseWave {
  PulseWave(this.name, Uint8List bytes, this.levels, {this.nativeFrames})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final String name;
  final Uint8List bytes;
  final List<double> levels;
  final List<String>? nativeFrames;
  late final String id = sha256.convert(bytes).toString().substring(0, 24);
  bool get deviceReady => nativeFrames != null;
  String frame(int tick) =>
      nativeFrames?[tick % nativeFrames!.length] ?? '0A0A0A0A00000000';

  static PulseWave parse(String filename, List<int> source) {
    if (source.isEmpty || source.length > 65536) {
      throw const FormatException('波形文件为空或超过 64 KiB');
    }
    final text = utf8.decode(source).replaceFirst('\uFEFF', '').trim();
    if (!text.startsWith('Dungeonlab+pulse:')) {
      throw const FormatException('不支持的波形格式');
    }
    final body = text.substring('Dungeonlab+pulse:'.length);
    final separator = body.indexOf('=');
    if (separator >= 0 &&
        !RegExp(r'^\d+(,\d+)*$').hasMatch(body.substring(0, separator))) {
      throw const FormatException('全局参数无效');
    }
    final sections = body.substring(separator + 1).split('+section+');
    if (sections.length > 10) throw const FormatException('分段数量超出范围');
    final levels = <double>[];
    for (final section in sections) {
      final parts = section.split('/');
      if (parts.length != 2) throw const FormatException('分段格式无效');
      final header = parts[0].split(',').map(int.parse).toList();
      if (header.length != 5 ||
          header.any((n) => n < 0 || n > 1000) ||
          ![0, 1].contains(header[4])) {
        throw const FormatException('分段参数无效');
      }
      final points = parts[1].split(',');
      if (points.length < 2 || points.length > 2048) {
        throw const FormatException('形状点数量无效');
      }
      final shape = <double>[];
      for (final point in points) {
        final match = RegExp(r'^(\d+(?:\.\d+)?)-([01])$').firstMatch(point);
        if (match == null) throw const FormatException('形状点格式无效');
        final level = double.parse(match[1]!);
        if (!level.isFinite || level > 100) throw const FormatException('幅度越界');
        shape.add(level / 100);
      }
      if (header[4] == 1) levels.addAll(shape);
    }
    if (levels.isEmpty) throw const FormatException('没有启用的波形分段');
    final basename = filename.replaceAll('\\', '/').split('/').last;
    final name = basename.replaceFirst(
      RegExp(r'\.pulse$', caseSensitive: false),
      '',
    );
    return PulseWave(
      name.substring(0, name.length.clamp(0, 120)),
      Uint8List.fromList(source),
      List.unmodifiable(levels),
    );
  }

  static List<PulseWave> builtins() => [
    _builtin('内置缓升缓降', [0, 10, 20, 30, 40, 50, 40, 30, 20, 10]),
    _builtin('内置间歇脉冲', [0, 0, 30, 30, 0, 0, 20, 20]),
  ];
  static PulseWave _builtin(String name, List<int> points) => PulseWave(
    name,
    Uint8List.fromList(utf8.encode(name)),
    points.map((e) => e / 100).toList(),
    nativeFrames: points
        .map((e) => '0A0A0A0A${e.toRadixString(16).padLeft(2, '0') * 4}')
        .toList(),
  );
}

class PulseImportResult {
  final waves = <PulseWave>[];
  final errors = <String>[];
  int duplicates = 0;
}

PulseImportResult importPulseFiles(String filename, List<int> bytes) {
  if (bytes.length > 8 * 1024 * 1024) {
    throw const FormatException('压缩包最大 8 MiB');
  }
  final result = PulseImportResult();
  final ids = <String>{};
  void add(String name, List<int> data) {
    try {
      final wave = PulseWave.parse(name, data);
      if (ids.add(wave.id)) {
        result.waves.add(wave);
      } else {
        result.duplicates++;
      }
    } catch (_) {
      result.errors.add(name.replaceAll('\\', '/').split('/').last);
    }
  }

  var total = 0;
  var entries = 0;
  void walk(String name, List<int> data, int depth) {
    final zipped =
        data.length >= 4 &&
        data[0] == 0x50 &&
        data[1] == 0x4b &&
        data[2] == 3 &&
        data[3] == 4;
    if (!zipped) {
      add(name, data);
      return;
    }
    if (depth > 2) throw const FormatException('嵌套压缩包过深');
    final archive = ZipDecoder().decodeBytes(data);
    entries += archive.length;
    if (entries > 1000) throw const FormatException('压缩包条目过多');
    for (final entry in archive) {
      // Some .pulse files are ZIP containers. Never extract archive paths.
      if (!entry.isFile || !entry.name.toLowerCase().endsWith('.pulse')) {
        continue;
      }
      if (entry.size > 65536 || (total += entry.size) > 16 * 1024 * 1024) {
        throw const FormatException('解压后波形过大');
      }
      walk(entry.name, entry.content, depth + 1);
    }
  }

  walk(filename, bytes, 0);
  return result;
}
