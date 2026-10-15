import 'dart:io';

import 'package:haptics_lab/realtime_probe.dart';
import 'package:haptics_lab/service/access_store.dart';
import 'package:haptics_lab/service/voice_service.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/beta_service.dart <private-state-directory>',
    );
    exitCode = 2;
    return;
  }
  final directory = Directory(args.single);
  await directory.create(recursive: true);
  final owner = File('${directory.path}/owner-token');
  if (!await owner.exists()) {
    await owner.writeAsString(secretToken(), flush: true);
  }
  final store = AccessStore(File('${directory.path}/accounts.json'));
  try {
    await store.open();
    // Created inside the operator's ACL-restricted directory, never packaged.
    final clientToken = File('${directory.path}/local-client-token');
    if (!await clientToken.exists()) {
      await clientToken.writeAsString(secretToken(), flush: true);
    }
    await store.configureLocalOwner((await clientToken.readAsString()).trim());
    final host = Platform.environment['HAPTICS_PROVIDER_HOST'],
        key = Platform.environment['HAPTICS_PROVIDER_KEY'];
    final service = VoiceService(
      store,
      adminToken: (await owner.readAsString()).trim(),
      provider: host != null && key != null ? ProbeConfig(host, key) : null,
    );
    SecurityContext? tls;
    final cert = Platform.environment['HAPTICS_TLS_CERT'],
        privateKey = Platform.environment['HAPTICS_TLS_KEY'];
    if (cert != null && privateKey != null) {
      tls = SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(privateKey);
    }
    await service.start(
      port: int.parse(Platform.environment['HAPTICS_PORT'] ?? '8790'),
      address: InternetAddress(
        Platform.environment['HAPTICS_BIND'] ?? '127.0.0.1',
      ),
      tls: tls,
    );
    stdout.writeln(
      'Beta service ready on port ${service.server.port}; provider configured: ${service.provider != null}. Credentials and conversation are not logged.',
    );
    ProcessSignal.sigint.watch().listen((_) async {
      await service.close();
      await store.close();
      exit(0);
    });
  } catch (_) {
    stderr.writeln(
      'Service startup failed. Check private state lock, provider configuration and TLS paths.',
    );
    await store.close();
    exitCode = 1;
  }
}
