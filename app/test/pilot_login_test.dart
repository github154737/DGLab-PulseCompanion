import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/app_access.dart';
import 'package:haptics_lab/pilot_login_page.dart';
import 'package:haptics_lab/warm_splash.dart';
import 'package:haptics_lab/warm_theme.dart';

const fixtureUserCode = 'TESTCODE23';
const fixtureAdminCode = 'Fixture-Admin';

bool fixtureVerifier(AppRole role, String credential) => verifyPilotCredential(
  role,
  credential,
  userCodeHashes: [sha256.convert(utf8.encode(fixtureUserCode)).toString()],
  adminCodeHash: sha256.convert(utf8.encode(fixtureAdminCode)).toString(),
);

PilotAccessController fixtureAccess({DateTime Function()? now}) =>
    PilotAccessController(verifier: fixtureVerifier, now: now);

Widget fixtureApp({
  PilotAccessController? access,
  bool splash = false,
  double textScale = 1,
}) {
  final gate = PilotLoginGate(
    accessController: access ?? fixtureAccess(),
    builder: (context, role, logout) => Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Text('authenticated:${role.name}'),
            TextButton(
              key: const Key('fixture_logout'),
              onPressed: logout,
              child: const Text('退出登录'),
            ),
            TextButton(
              key: const Key('fixture_push'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: Column(
                      children: [
                        const Text('authenticated:detail'),
                        TextButton(
                          key: const Key('fixture_nested_logout'),
                          onPressed: logout,
                          child: const Text('退出登录'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              child: const Text('进入详情'),
            ),
          ],
        ),
      ),
    ),
  );
  return MaterialApp(
    theme: warmTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: splash ? WarmSplash(child: gate) : gate,
  );
}

Future<void> submit(WidgetTester tester, String value) async {
  final field = find.byKey(const Key('pilot_credential'));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.ensureVisible(find.byKey(const Key('pilot_submit')));
  await tester.tap(find.byKey(const Key('pilot_submit')));
  await tester.pumpAndSettle();
}

Future<void> chooseRole(WidgetTester tester, AppRole role) async {
  final picker = find.byKey(Key('pilot_role_${role.name}'));
  await tester.ensureVisible(picker);
  await tester.tap(picker);
  await tester.pumpAndSettle();
}

void main() {
  test('hashed credentials normalize user case, keep administrator case', () {
    expect(fixtureVerifier(AppRole.user, ' testcode23 '), isTrue);
    expect(fixtureVerifier(AppRole.user, 'TESTCODE2'), isFalse);
    expect(fixtureVerifier(AppRole.user, 'TESTCODE234'), isFalse);
    expect(fixtureVerifier(AppRole.user, 'TEST CODE2'), isFalse);
    expect(
      fixtureVerifier(AppRole.administrator, ' $fixtureAdminCode '),
      isTrue,
    );
    expect(fixtureVerifier(AppRole.administrator, 'fixture-admin'), isFalse);
    expect(fixtureVerifier(AppRole.user, fixtureAdminCode), isFalse);
    expect(fixtureVerifier(AppRole.administrator, fixtureUserCode), isFalse);
  });

  test(
    'five failures lock both roles; a correct code cannot bypass lockout',
    () {
      var now = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final access = PilotAccessController(
        now: () => now,
        verifier: (role, credential) {
          calls++;
          return fixtureVerifier(role, credential);
        },
      );
      for (var index = 0; index < 4; index++) {
        expect(
          access.attempt(AppRole.user, 'incorrect'),
          PilotAccessAttempt.rejected,
        );
      }
      expect(
        access.attempt(AppRole.administrator, 'incorrect'),
        PilotAccessAttempt.locked,
      );
      expect(access.remainingSeconds, 30);
      expect(
        access.attempt(AppRole.administrator, fixtureAdminCode),
        PilotAccessAttempt.locked,
      );
      expect(
        access.attempt(AppRole.user, fixtureUserCode),
        PilotAccessAttempt.locked,
      );
      expect(calls, 5);
      now = now.add(const Duration(seconds: 29, milliseconds: 500));
      expect(access.remainingSeconds, 1);
      expect(
        access.attempt(AppRole.user, fixtureUserCode),
        PilotAccessAttempt.locked,
      );
      now = now.add(const Duration(milliseconds: 500));
      expect(
        access.attempt(AppRole.user, fixtureUserCode),
        PilotAccessAttempt.accepted,
      );
      expect(access.failedAttempts, 0);
      expect(access.remainingSeconds, 0);
      expect(calls, 6);
    },
  );

  test('verifier failure fails closed and counts toward local lockout', () {
    final access = PilotAccessController(
      verifier: (_, _) => throw StateError('fixture unavailable'),
    );
    expect(
      access.attempt(AppRole.administrator, fixtureAdminCode),
      PilotAccessAttempt.rejected,
    );
    expect(access.failedAttempts, 1);
  });

  testWidgets('login follows splash and defaults to user access', (
    tester,
  ) async {
    await tester.pumpWidget(fixtureApp(splash: true));
    expect(find.byKey(const Key('warm_splash')), findsOneWidget);
    expect(find.byKey(const Key('pilot_login')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pilot_login')), findsOneWidget);
    await submit(tester, ' testcode23 ');
    expect(find.text('authenticated:user'), findsOneWidget);
    expect(find.text('authenticated:administrator'), findsNothing);
    expect(find.byKey(const Key('pilot_login')), findsNothing);
  });

  testWidgets('administrator requires the administrator role and key', (
    tester,
  ) async {
    await tester.pumpWidget(fixtureApp());
    await submit(tester, fixtureAdminCode);
    expect(find.byKey(const Key('pilot_login_error')), findsOneWidget);
    await chooseRole(tester, AppRole.administrator);
    await submit(tester, fixtureUserCode);
    expect(find.byKey(const Key('pilot_login_error')), findsOneWidget);
    await submit(tester, fixtureAdminCode);
    expect(find.text('authenticated:administrator'), findsOneWidget);
    expect(find.text('authenticated:user'), findsNothing);
  });

  testWidgets('secret visibility is explicit and switching role clears input', (
    tester,
  ) async {
    await tester.pumpWidget(fixtureApp());
    final field = find.byKey(const Key('pilot_credential'));
    var widget = tester.widget<TextField>(field);
    expect(widget.obscureText, isTrue);
    expect(widget.autocorrect, isFalse);
    expect(widget.enableSuggestions, isFalse);
    expect(widget.enableIMEPersonalizedLearning, isFalse);
    await tester.enterText(field, 'fixture');
    await tester.tap(find.byKey(const Key('pilot_toggle_secret')));
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isFalse);
    await chooseRole(tester, AppRole.administrator);
    widget = tester.widget<TextField>(field);
    expect(widget.controller!.text, isEmpty);
    expect(widget.obscureText, isTrue);
  });

  testWidgets('role switch and keyboard submit cannot bypass cooldown', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 1, 1);
    final access = fixtureAccess(now: () => now);
    await tester.pumpWidget(fixtureApp(access: access));
    for (var index = 0; index < 5; index++) {
      await submit(tester, 'incorrect');
    }
    expect(find.textContaining('30 秒后重试'), findsOneWidget);
    await chooseRole(tester, AppRole.administrator);
    final field = find.byKey(const Key('pilot_credential'));
    await tester.enterText(field, fixtureAdminCode);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.byKey(const Key('pilot_login')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('pilot_submit')))
          .onPressed,
      isNull,
    );
    now = now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await submit(tester, fixtureAdminCode);
    expect(find.text('authenticated:administrator'), findsOneWidget);
  });

  testWidgets('logout clears input and removes nested authorized routes', (
    tester,
  ) async {
    await tester.pumpWidget(fixtureApp());
    await chooseRole(tester, AppRole.administrator);
    await submit(tester, fixtureAdminCode);
    await tester.tap(find.byKey(const Key('fixture_push')));
    await tester.pumpAndSettle();
    expect(find.text('authenticated:detail'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fixture_nested_logout')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pilot_login')), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const Key('pilot_credential')),
    );
    expect(field.controller!.text, isEmpty);
    expect(field.obscureText, isTrue);
    expect(field.decoration!.labelText, '内测码');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pilot_login')), findsOneWidget);
    expect(find.textContaining('authenticated:'), findsNothing);
    await submit(tester, fixtureUserCode);
    expect(find.text('authenticated:user'), findsOneWidget);
    expect(find.text('authenticated:detail'), findsNothing);
  });

  testWidgets('remount does not restore an authenticated session', (
    tester,
  ) async {
    final access = fixtureAccess();
    await tester.pumpWidget(fixtureApp(access: access));
    await submit(tester, fixtureUserCode);
    expect(find.text('authenticated:user'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(fixtureApp(access: access));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pilot_login')), findsOneWidget);
  });

  for (final scenario in [
    (const Size(320, 568), 1.0),
    (const Size(320, 568), 2.0),
    (const Size(844, 390), 1.0),
    (const Size(800, 1280), 2.0),
  ]) {
    testWidgets('login fits ${scenario.$1}, scale ${scenario.$2}, keyboard', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(scenario.$1);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(fixtureApp(textScale: scenario.$2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final role in AppRole.values) {
        await chooseRole(tester, role);
        final field = find.byKey(const Key('pilot_credential'));
        await tester.ensureVisible(field);
        await tester.enterText(field, 'incorrect');
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('pilot_submit')));
        await tester.tap(find.byKey(const Key('pilot_submit')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: role.name);
        expect(find.byKey(const Key('pilot_login_error')), findsOneWidget);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
