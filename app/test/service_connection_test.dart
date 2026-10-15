import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/app_access.dart';
import 'package:haptics_lab/public_setup_page.dart';
import 'package:haptics_lab/service_connection.dart';
import 'package:haptics_lab/venice_route.dart';
import 'package:haptics_lab/pulse_library.dart';

Map<String, dynamic> fixture() => {
  'format': 'aihaptics-connection',
  'version': 1,
  'url': 'https://relay.example.com/api/v1',
  'token': 'fixture-token',
};
List<int> encode(Map<String, dynamic> value) => utf8.encode(jsonEncode(value));

void main() {
  tearDown(() => VeniceRoute.configurePublic());
  test(
    'connection import validates schema, destination and credential isolation',
    () {
      expect(ServiceConnection.parse(encode(fixture())).token, 'fixture-token');
      for (final patch in [
        {'version': 2},
        {'developerTools': true},
        {'prompt': 'override'},
        {'url': 'http://relay.example.com/api/v1'},
        {'url': 'https://user@relay.example.com/api/v1'},
        {'url': 'https://relay.example.com/api/v1?token=secret'},
        {'token': 'VENICE_INFERENCE_KEY_fixture'},
        {'token': 'x\r\nheader'},
        {'token': 123},
        {'certificate': 'not-a-certificate'},
      ]) {
        expect(
          () => ServiceConnection.parse(encode({...fixture(), ...patch})),
          throwsA(anything),
        );
      }
      expect(
        () => ServiceConnection.parse(List.filled(32769, 32)),
        throwsFormatException,
      );
      expect(VeniceRoute.isRelay, isFalse);
    },
  );
  test('public resource bundle has no private waveform collection', () {
    final bytes = File('assets/user-waveforms.zip').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.files.map((e) => e.name), ['README.txt']);
    expect(importPulseFiles('library.zip', bytes).waves, isEmpty);
    expect(PulseWave.builtins().length, 2);
  });
  testWidgets(
    'import previews destination without connecting or enabling developer tools',
    (tester) async {
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: PublicSetupGate(
            readConnectionFile: () async => encode(fixture()),
            sessionBuilder: (role, loadKey, close) {
              opened = true;
              expect(role, AppRole.user);
              return Scaffold(
                body: TextButton(onPressed: close, child: const Text('close')),
              );
            },
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('public_import')));
      await tester.pumpAndSettle();
      expect(opened, isFalse);
      expect(VeniceRoute.isRelay, isFalse);
      expect(find.textContaining('将连接：relay.example.com'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('public_enter')));
      await tester.tap(find.byKey(const Key('public_enter')));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      expect(VeniceRoute.relayToken, 'fixture-token');
      await tester.tap(find.text('close'));
      await tester.pumpAndSettle();
      expect(VeniceRoute.relayToken, isEmpty);
    },
  );
  testWidgets('invalid file cannot partially replace entered credentials', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PublicSetupGate(
          readConnectionFile: () async =>
              encode({...fixture(), 'developerTools': true}),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('public_credential')),
      'original',
    );
    await tester.tap(find.byKey(const Key('public_import')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('public_credential')))
          .controller!
          .text,
      'original',
    );
    expect(find.textContaining('连接文件无效'), findsOneWidget);
    expect(VeniceRoute.isRelay, isFalse);
  });
}
