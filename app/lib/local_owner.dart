import 'dart:io';

import 'beta_api.dart';

/// No provider or administrator credential is exposed to the desktop client.
class LocalOwner {
  static bool eligible(String address, {bool? windows}) {
    final uri = Uri.tryParse(address);
    return (windows ?? Platform.isWindows) &&
        uri != null &&
        uri.scheme == 'http' &&
        uri.host == '127.0.0.1' &&
        uri.port == 8790 &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        (uri.path.isEmpty || uri.path == '/');
  }

  static Future<BetaApi> connect(String address) async {
    if (!eligible(address)) throw StateError('local_owner_only');
    final root = Platform.environment['LOCALAPPDATA'];
    if (root == null) throw StateError('local_profile_missing');
    final file = File(
      '$root/AIHaptics/private/beta-service/local-client-token',
    );
    final api = BetaApi(address)..token = (await file.readAsString()).trim();
    final account = await api.request('/v1/me');
    if (account['user'] != 'local-owner') throw StateError('owner_required');
    return api;
  }
}
