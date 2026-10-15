// Optional CPU-rendered login preview. No network, real codes, or login session.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/app_access.dart';
import 'package:haptics_lab/pilot_login_page.dart';
import 'package:haptics_lab/warm_theme.dart';

void main() {
  testWidgets('render pilot login screens for visual review', (tester) async {
    const output = String.fromEnvironment('PILOT_PREVIEW_DIR');
    expect(output, isNotEmpty);
    final folder = Directory(output);
    await tester.runAsync(() async {
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
    });
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(tester.view.resetViewInsets);
    await tester.binding.setSurfaceSize(const Size(412, 915));
    final boundaryKey = GlobalKey();
    final access = PilotAccessController(verifier: (_, _) => false);

    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull, reason: name);
      final field = tester.widget<TextField>(
        find.byKey(const Key('pilot_credential')),
      );
      expect(field.controller!.text, isEmpty);
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final frame = await boundary.toImage(pixelRatio: 2);
        try {
          final png = await frame.toByteData(format: ui.ImageByteFormat.png);
          await File('${folder.path}/pilot-login-$name.png')
              .writeAsBytes(png!.buffer.asUint8List());
        } finally {
          frame.dispose();
        }
      });
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: warmTheme(),
          home: PilotLoginGate(
            accessController: access,
            builder: (_, _, _) => const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await capture('user');
    await tester.tap(find.byKey(const Key('pilot_role_administrator')));
    await tester.pumpAndSettle();
    await capture('administrator');

    await tester.tap(find.byKey(const Key('pilot_role_user')));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(320, 568));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('pilot_credential'));
    await tester.ensureVisible(field);
    await tester.showKeyboard(field);
    tester.view.viewInsets = FakeViewPadding(
      bottom: 260 * tester.view.devicePixelRatio,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('pilot_submit')));
    await tester.pumpAndSettle();
    await capture('user-small-keyboard');
    await tester.pumpWidget(const SizedBox());
  }, skip: !const bool.fromEnvironment('PILOT_UI_PREVIEW'));
}
