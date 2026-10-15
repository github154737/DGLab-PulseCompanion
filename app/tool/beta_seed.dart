import 'dart:convert';
import 'dart:io';

import 'package:haptics_lab/service/access_store.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Usage: beta_seed.dart <private-state-directory>');
    exitCode = 2;
    return;
  }
  final dir = Directory(args.single),
      export = File('${args.single}/invites-once.json');
  await dir.create(recursive: true);
  final store = AccessStore(File('${dir.path}/accounts.json'));
  try {
    await store.open();
    if (await export.exists() ||
        store.invites.isNotEmpty ||
        store.users.isNotEmpty) {
      stdout.writeln(
        'Private beta state already initialized; no codes changed.',
      );
      return;
    }
    final invites = await store.createInvites(5);
    await export.writeAsString(
      const JsonEncoder.withIndent('  ').convert({'invites': invites}),
      flush: true,
    );
    stdout.writeln(
      'Five local beta invitations initialized. Plaintext export is only in the protected private directory; no provider credentials configured.',
    );
  } catch (_) {
    stderr.writeln(
      'Initialization failed; check state lock and private directory permissions.',
    );
    exitCode = 1;
  } finally {
    await store.close();
  }
}
