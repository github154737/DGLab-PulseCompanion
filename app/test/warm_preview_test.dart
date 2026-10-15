import 'package:haptics_lab/app_access.dart';

// Optional CPU-rendered UI review, with local CJK fonts and no emulator/API.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_chat_page.dart';
import 'package:haptics_lab/venice_wave_session.dart';

import 'warm_test_helpers.dart';

void main() {
  testWidgets('render warm UI for visual review', (tester) async {
    final output = const String.fromEnvironment('WARM_PREVIEW_DIR');
    expect(output, isNotEmpty);
    final folder = Directory(output);
    final prefs = await tester.runAsync(() async {
      await folder.create(recursive: true);
      final bytes = await File(
        '${Platform.environment['WINDIR']}/Fonts/msyh.ttc',
      ).readAsBytes();
      for (final family in ['Roboto', 'sans-serif']) {
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      return Directory.systemTemp.createTemp('warm-preview-');
    });
    await tester.binding.setSurfaceSize(const Size(412, 915));
    final boundaryKey = GlobalKey();
    final waves = VeniceWaveSession();
    Future<void> capture(String name) async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final frame = await boundary.toImage(pixelRatio: 2);
        final png = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File('${folder.path}/warm-final-$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
        frame.dispose();
      });
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: VeniceChatPage(
            role: AppRole.administrator,
            enableDialogueGuidance: false,
            waveSession: waves,
            loadKey: () async => 'fixture',
            preferencesDirectory: prefs,
          ),
        ),
      ),
    );
    await settleWarm(tester);
    await settleWarm(tester);
    for (final tab in ['chat', 'interaction', 'mine']) {
      await tapWarm(tester, 'nav_$tab');
      expect(tester.takeException(), isNull);
      await capture(tab);
      if (tab == 'chat') {
        await tapWarm(tester, 'show_recording');
        await capture('chat-voice-input');
        await tapWarm(tester, 'show_recording');
      }
    }
    await tapWarm(tester, 'nav_interaction');
    waves.grant();
    waves.apply({
      'action': 'set',
      'a': 4,
      'b': 4,
      'waveform_id': waves.selected,
    }, waves.epoch);
    await tester.pump(const Duration(milliseconds: 100));
    await capture('playing');
    waves.stop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage_candidates')));
    await tester.pumpAndSettle();
    await capture('candidates');
    await tester.pumpWidget(const SizedBox());
    await settleWarm(tester);
    await tester.runAsync(() => prefs!.delete(recursive: true));
    waves.dispose();
    await tester.binding.setSurfaceSize(null);
  }, skip: !const bool.fromEnvironment('WARM_UI_PREVIEW'));
}
