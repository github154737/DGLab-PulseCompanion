import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'beta_api.dart';

class AccountVault {
  static const channel = MethodChannel('aihaptics/pcm');
  Future<File> file() async => File(
    '${(await getApplicationSupportDirectory()).path}/beta-account.sealed',
  );
  Future<void> save(BetaApi api) async {
    final raw = Uint8List.fromList(
      utf8.encode(
        jsonEncode({'address': api.base.toString(), 'token': api.token}),
      ),
    );
    final sealed = await channel.invokeMethod<Uint8List>('seal', raw);
    raw.fillRange(0, raw.length, 0);
    if (sealed == null) throw StateError('vault_unavailable');
    final target = await file();
    await target.parent.create(recursive: true);
    final pending = File('${target.path}.pending');
    await pending.writeAsBytes(sealed, flush: true);
    await pending.rename(target.path);
  }

  Future<BetaApi?> load() async {
    final target = await file();
    if (!await target.exists()) return null;
    if (await target.length() > 16384) throw StateError('vault_invalid');
    final raw = await channel.invokeMethod<Uint8List>(
      'unseal',
      await target.readAsBytes(),
    );
    if (raw == null) throw StateError('vault_unavailable');
    try {
      final value = jsonDecode(utf8.decode(raw));
      return BetaApi(value['address'] as String)
        ..token = value['token'] as String;
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
  }

  Future<void> clear() async {
    final target = await file();
    if (await target.exists()) await target.delete();
  }
}
