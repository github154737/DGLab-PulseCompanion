import 'dart:convert';
import 'dart:io';

import 'core_bridge.dart';

/// Stores only imported waveforms, never session authorization or chat messages.
class WaveformStore {
  WaveformStore(this.directory, this.core);
  final Directory directory;
  final CoreBridge core;
  String? _id(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(value) ? value : null;
  Future<List<String>> restore() async {
    final errors = <String>[];
    if (!await directory.exists()) return errors;
    var count = 0;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      if (++count > 24) {
        errors.add('只恢复前 24 个波形');
        break;
      }
      try {
        if (await entry.length() > 32768) throw const FormatException('文件过大');
        final source = await entry.readAsString();
        final validated = core.call({
          'op': 'validate_waveform',
          'source': source,
        });
        if (validated['ok'] != true) throw const FormatException('波形无效');
        final id = validated['result']['canonical']['id'] as String;
        if (entry.uri.pathSegments.last != '$id.json') {
          throw const FormatException('文件名与波形 ID 不一致');
        }
        final result = core.call({'op': 'import_waveform', 'source': source});
        if (result['ok'] != true &&
            result['error'] != 'duplicate_waveform_id') {
          throw FormatException(result['error'].toString());
        }
      } catch (_) {
        errors.add('有一个波形未通过校验，已保留原文件');
      }
    }
    return errors;
  }

  Future<void> save(Map<String, dynamic> canonical) async {
    final id = _id(canonical['id'] as String);
    if (id == null) throw const FormatException('invalid id');
    final content = jsonEncode(canonical);
    if (utf8.encode(content).length > 32768) {
      throw const FormatException('文件过大');
    }
    await directory.create(recursive: true);
    final file = File('${directory.path}/$id.json');
    if (await file.exists()) throw const FileSystemException('同名波形文件已存在');
    final pending = File('${directory.path}/$id.json.pending');
    await pending.writeAsString(content, flush: true);
    await pending.rename(file.path);
  }

  Future<void> remove(String value) async {
    final id = _id(value);
    if (id == null) throw const FormatException('invalid id');
    final file = File('${directory.path}/$id.json');
    if (await file.exists()) await file.delete();
  }
}
