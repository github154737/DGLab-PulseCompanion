import 'package:flutter/material.dart';

import 'pilot_access_codes.dart';
import 'pilot_login_page.dart';
import 'public_setup_page.dart';
import 'venice_chat_page.dart';

/// Build profiles are independent of credentials and device authorization.
class AppDistribution {
  const AppDistribution({
    this.edition = 'public',
    this.loginEnabled = false,
    this.developerTools = false,
  });
  static const compiled = AppDistribution(
    edition: String.fromEnvironment('APP_EDITION', defaultValue: 'public'),
    loginEnabled: bool.fromEnvironment('APP_LOGIN_ENABLED'),
    developerTools: bool.fromEnvironment('APP_DEVELOPER_TOOLS'),
  );
  final String edition;
  final bool loginEnabled;
  final bool developerTools;

  String? validate({
    required bool hasPilotCodes,
    required bool hasEmbeddedService,
  }) {
    if (edition != 'public' && edition != 'pilot') return '构建版本配置无效';
    if (edition == 'public' &&
        (loginEnabled || hasPilotCodes || hasEmbeddedService)) {
      return '公开版不能包含内测登录或私有服务配置';
    }
    if (edition == 'pilot' &&
        (!loginEnabled || !hasPilotCodes || developerTools)) {
      return '内测版需要完整的登录配置，开发权限由登录身份决定';
    }
    return null;
  }
}

class DistributionGate extends StatelessWidget {
  const DistributionGate({super.key});
  @override
  Widget build(BuildContext context) {
    const profile = AppDistribution.compiled;
    final hasCodes =
        RegExp(r'^[a-f0-9]{64}$').hasMatch(pilotAdminCodeHash) &&
        RegExp(r'^[a-f0-9]{64}(,[a-f0-9]{64})*$')
            .hasMatch(pilotUserCodeHashList) &&
        pilotUserCodeHashes.toSet().length == pilotUserCodeHashes.length &&
        !pilotUserCodeHashes.contains(pilotAdminCodeHash);
    final error = profile.validate(
      hasPilotCodes: profile.edition == 'public'
          ? pilotAdminCodeHash.isNotEmpty || pilotUserCodeHashList.isNotEmpty
          : hasCodes,
      hasEmbeddedService:
          const String.fromEnvironment('VENICE_RELAY_URL').isNotEmpty ||
          const String.fromEnvironment('VENICE_RELAY_TOKEN').isNotEmpty ||
          const String.fromEnvironment('VENICE_RELAY_CERT').isNotEmpty ||
          const String.fromEnvironment('VENICE_LOCAL_TEST_KEY').isNotEmpty ||
          const String.fromEnvironment('BETA_SERVICE_URL').isNotEmpty,
    );
    if (error != null) {
      return Scaffold(
        body: SafeArea(child: Center(child: Text(error))),
      );
    }
    if (profile.loginEnabled) {
      return PilotLoginGate(
        builder: (context, role, logout) =>
            VeniceChatPage(role: role, onLogout: logout),
      );
    }
    return PublicSetupGate(initialDeveloperTools: profile.developerTools);
  }
}
