import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/main.dart';
import 'package:haptics_lab/release_panel.dart';

Future<Directory> noStorage() async =>
    throw StateError('test storage unavailable');
void main() {
  setUp(() => CoreBridge().call({'op': 'reset_simulation'}));
  test('release manifest compares numeric versions and rejects unsafe download schemes', () {
    Map<String, dynamic> data(String v, String url) => {
      'format': 'haptics_release_v1',
      'version': v,
      'announcement': 'Fixture announcement',
      'download_url': url,
    };
    expect(
      ReleaseManifest.parse(data('0.10.0', 'https://example.org/release'))
          .newer,
      true,
    );
    expect(
      ReleaseManifest.parse(data('0.4.9', 'https://example.org/release')).newer,
      false,
    );
    expect(
      () => ReleaseManifest.parse(data('0.6.0', 'file:///test')),
      throwsFormatException,
    );
    expect(
      () => ReleaseManifest.parse(data('9.0', 'https://example.org/release')),
      throwsFormatException,
    );
  });
  testWidgets(
    'English mobile navigation and expanded feature panels fit narrow screens',
    (tester) async {
      final layoutErrors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError!;
      FlutterError.onError = (details) {
        layoutErrors.add(details);
        previous(details);
      };
      addTearDown(() => FlutterError.onError = previous);
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const HapticsApp(waveformDirectory: noStorage));
      await tester.pump();
      await tester.tap(find.byTooltip('Language / 语言'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(find.text('Haptics Lab'), findsOneWidget);
      for (final label in [
        'Characters & interaction',
        'Automatic conversation rounds',
        'Story exploration',
      ]) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        if (label != 'Characters & interaction') {
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
        }
        expect(
          tester.takeException(),
          isNull,
          reason: layoutErrors.map((e) => e.toString()).join('\n'),
        );
      }
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      expect(find.text('Getting started'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'long Space stops outside editing; release and text input cancel it',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const HapticsApp(waveformDirectory: noStorage));
      await tester.pump();
      await tester.tap(find.byKey(const Key('device_sim_single')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('authorize')));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(seconds: 1));
      expect(
        CoreBridge().call({'op': 'snapshot'})['state']['phase'],
        'authorized',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(
        CoreBridge().call({'op': 'snapshot'})['state']['phase'],
        'stopped',
      );
      await tester.ensureVisible(find.byKey(const Key('chat_input')));
      await tester.showKeyboard(find.byKey(const Key('chat_input')));
      await tester.pump();
      CoreBridge().call({'op': 'authorize', 'limit': 0.3, 'lease_ms': 30000});
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(
        CoreBridge().call({'op': 'snapshot'})['state']['phase'],
        'authorized',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
