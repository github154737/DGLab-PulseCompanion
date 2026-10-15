import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/app_access.dart';
import 'package:haptics_lab/app_distribution.dart';
import 'package:haptics_lab/public_setup_page.dart';
import 'package:haptics_lab/venice_route.dart';
import 'package:haptics_lab/warm_theme.dart';

void main() {
  tearDown(() => VeniceRoute.configurePublic());

  test('profiles reject mixed secrets, disabled pilot login and global pilot developer access', () {
    expect(
      const AppDistribution().validate(
        hasPilotCodes: false,
        hasEmbeddedService: false,
      ),
      isNull,
    );
    expect(
      const AppDistribution().validate(
        hasPilotCodes: true,
        hasEmbeddedService: false,
      ),
      isNotNull,
    );
    expect(
      const AppDistribution().validate(
        hasPilotCodes: false,
        hasEmbeddedService: true,
      ),
      isNotNull,
    );
    expect(
      const AppDistribution(loginEnabled: true)
          .validate(hasPilotCodes: false, hasEmbeddedService: false),
      isNotNull,
    );
    expect(
      const AppDistribution(
        edition: 'pilot',
        loginEnabled: true,
      ).validate(hasPilotCodes: true, hasEmbeddedService: true),
      isNull,
    );
    expect(
      const AppDistribution(edition: 'pilot')
          .validate(hasPilotCodes: true, hasEmbeddedService: true),
      isNotNull,
    );
    expect(
      const AppDistribution(
        edition: 'pilot',
        loginEnabled: true,
      ).validate(hasPilotCodes: false, hasEmbeddedService: true),
      isNotNull,
    );
    expect(
      const AppDistribution(
        edition: 'pilot',
        loginEnabled: true,
        developerTools: true,
      ).validate(hasPilotCodes: true, hasEmbeddedService: true),
      isNotNull,
    );
  });

  test('relay validation fails before changing current route and retains TLS verification', () {
    VeniceRoute.configurePublic(
      url: 'https://relay.example.com/api/v1',
      token: 'fixture-relay',
    );
    for (final url in [
      'http://relay.example.com/api/v1',
      'https://user@relay.example.com/api/v1',
      'https://relay.example.com/api/v1?x=1',
      'https://relay.example.com/api/v1#x',
    ]) {
      expect(
        () => VeniceRoute.configurePublic(url: url, token: 'fixture'),
        throwsFormatException,
      );
      expect(VeniceRoute.base.host, 'relay.example.com');
    }
    expect(
      () => VeniceRoute.configurePublic(
        url: 'https://other.example.com/api/v1',
        token: 'fixture',
        certificate: 'invalid',
      ),
      throwsA(anything),
    );
    expect(VeniceRoute.base.host, 'relay.example.com');
    expect(
      () => VeniceRoute.configurePublic(
        url: 'https://other.example.com/api/v1',
        token: 'VENICE_INFERENCE_KEY_fixture',
      ),
      throwsFormatException,
    );
    expect(
      () => VeniceRoute.configurePublic(
        url: 'https://other.example.com/api/v1',
        token: 'fixture\r\nInjected',
      ),
      throwsFormatException,
    );
    final client = VeniceRoute.client(VeniceRoute.base);
    client.close(
      force: true,
    ); // No actual request; default trust roots, no badCertificateCallback.
    VeniceRoute.configurePublic();
    expect(VeniceRoute.isRelay, isFalse);
    expect(VeniceRoute.relayToken, isEmpty);
  });

  testWidgets(
    'public entry has setup instead of pilot login, does not open session automatically',
    (tester) async {
      var mountedSession = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: warmTheme(),
          home: PublicSetupGate(
            sessionBuilder: (_, _, _) {
              mountedSession = true;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(find.text('配置你的服务'), findsOneWidget);
      expect(find.byKey(const Key('pilot_login')), findsNothing);
      expect(mountedSession, isFalse);
      expect(VeniceRoute.isRelay, isFalse);
    },
  );

  testWidgets(
    'public offline user has no credential; returning clears session',
    (tester) async {
      Future<String> Function()? loader;
      AppRole? role;
      await tester.pumpWidget(
        MaterialApp(
          theme: warmTheme(),
          home: PublicSetupGate(
            sessionBuilder: (r, load, close) {
              role = r;
              loader = load;
              return Scaffold(
                body: TextButton(
                  onPressed: close,
                  child: const Text('close-session'),
                ),
              );
            },
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('public_offline')));
      await tester.tap(find.byKey(const Key('public_offline')));
      await tester.pumpAndSettle();
      expect(role, AppRole.user);
      await expectLater(loader!(), throwsStateError);
      await tester.tap(find.text('close-session'));
      await tester.pumpAndSettle();
      expect(find.text('配置你的服务'), findsOneWidget);
      expect(VeniceRoute.relayToken, isEmpty);
    },
  );

  testWidgets(
    'public developer tools explicit opt-in; credential only in session and cleared on return',
    (tester) async {
      Future<String> Function()? loader;
      AppRole? role;
      await tester.pumpWidget(
        MaterialApp(
          theme: warmTheme(),
          home: PublicSetupGate(
            sessionBuilder: (r, load, close) {
              role = r;
              loader = load;
              return Scaffold(
                body: TextButton(
                  onPressed: close,
                  child: const Text('close-session'),
                ),
              );
            },
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('public_credential')),
        'VENICE_INFERENCE_KEY_synthetic_test_only',
      );
      await tester.ensureVisible(find.byKey(const Key('public_advanced')));
      await tester.tap(find.byKey(const Key('public_advanced')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('public_developer_tools')),
      );
      await tester.tap(find.byKey(const Key('public_developer_tools')));
      await tester.ensureVisible(find.byKey(const Key('public_enter')));
      await tester.tap(find.byKey(const Key('public_enter')));
      await tester.pumpAndSettle();
      expect(role, AppRole.administrator);
      expect(await loader!(), 'VENICE_INFERENCE_KEY_synthetic_test_only');
      await tester.tap(find.text('close-session'));
      await tester.pumpAndSettle();
      await expectLater(loader!(), throwsStateError);
      final field = tester.widget<TextField>(
        find.byKey(const Key('public_credential')),
      );
      expect(field.controller!.text, isEmpty);
    },
  );

  testWidgets('invalid relay setup does not open session', (tester) async {
    var called = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: warmTheme(),
        home: PublicSetupGate(
          sessionBuilder: (_, _, _) {
            called = true;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('public_relay')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('public_address')),
      'http://relay.example.com/api/v1',
    );
    await tester.enterText(
      find.byKey(const Key('public_credential')),
      'fixture',
    );
    await tester.ensureVisible(find.byKey(const Key('public_enter')));
    await tester.tap(find.byKey(const Key('public_enter')));
    await tester.pumpAndSettle();
    expect(called, isFalse);
    expect(find.textContaining('配置无效'), findsOneWidget);
    expect(VeniceRoute.isRelay, isFalse);
  });

  testWidgets('small setup remains scrollable with keyboard', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: warmTheme(), home: const PublicSetupGate()),
    );
    await tester.tap(find.byKey(const Key('public_relay')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('public_enter')));
    expect(tester.takeException(), isNull);
  });
}
