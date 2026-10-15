import 'dart:convert';
import 'dart:io';

/// Explicitly saved preferences only. No key, transcript, device, or grant.
class PreferencesStore {
  PreferencesStore(this.directory);
  final Directory directory;
  File get file => File('${directory.path}/conversation-settings-v1.json');

  static Map<String, dynamic> validate(Object? value) {
    const keys = {
      'version',
      'source',
      'replyMode',
      'temperature',
      'timeoutSeconds',
      'maxTokens',
      'localEndpoint',
      'apiEndpoint',
      'model',
      'persona',
      'style',
    };
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains) ||
        value['version'] != 1 ||
        !['demo', 'local', 'api'].contains(value['source']) ||
        !['tools', 'json'].contains(value['replyMode']) ||
        !['温柔', '俏皮', '简洁'].contains(value['style']) ||
        ![15, 30, 60, 120].contains(value['timeoutSeconds']) ||
        ![600, 1200, 2400].contains(value['maxTokens'])) {
      throw const FormatException('配置格式不正确');
    }
    final temperature = value['temperature'];
    if (temperature is! num ||
        !temperature.isFinite ||
        temperature < 0 ||
        temperature > 1) {
      throw const FormatException('对话灵活度不正确');
    }
    for (final entry in {
      'model': 120,
      'persona': 1000,
      'localEndpoint': 2048,
      'apiEndpoint': 2048,
    }.entries) {
      final text = value[entry.key];
      if (text is! String || text.length > entry.value) {
        throw const FormatException('配置文字过长或格式不正确');
      }
    }
    for (final key in ['localEndpoint', 'apiEndpoint']) {
      final text = value[key] as String;
      if (text.isEmpty) continue;
      final uri = Uri.tryParse(text);
      final local =
          uri != null && ['localhost', '127.0.0.1', '::1'].contains(uri.host);
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !(key == 'localEndpoint'
              ? uri.scheme == 'http' && local
              : uri.scheme == 'https' || uri.scheme == 'http' && local)) {
        throw const FormatException('请使用有效服务地址，地址中不能包含密钥或查询参数');
      }
    }
    return Map<String, dynamic>.from(value);
  }

  Future<Map<String, dynamic>?> load() async {
    if (!await file.exists()) return null;
    final bytes = <int>[];
    await for (final part in file.openRead()) {
      if (bytes.length + part.length > 16384) {
        throw const FormatException('配置文件过大');
      }
      bytes.addAll(part);
    }
    return validate(jsonDecode(utf8.decode(bytes)));
  }

  Future<void> save(Map<String, dynamic> preferences) async {
    final text = jsonEncode(validate(preferences));
    await directory.create(recursive: true);
    final pending = File('${file.path}.pending');
    await pending.writeAsString(text, flush: true);
    await pending.rename(file.path);
  }

  Future<void> forget() async {
    for (final path in [file.path, '${file.path}.pending']) {
      final saved = File(path);
      if (await saved.exists()) await saved.delete();
    }
  }
}
