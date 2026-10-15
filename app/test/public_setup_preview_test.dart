// Optional local visual review; does not run in CI or ordinary test suites.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/public_setup_page.dart';
import 'package:haptics_lab/warm_theme.dart';

void main() {
  testWidgets('public setup preview', (tester) async {
    await tester.runAsync(() async {
      final bytes = await File(
        '${Platform.environment['WINDIR']}/Fonts/msyh.ttc',
      ).readAsBytes();
      for (final name in ['Roboto', 'sans-serif']) {
        await (FontLoader(
          name,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(412, 915));
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: warmTheme(),
          home: const PublicSetupGate(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(Platform.environment['PUBLIC_PREVIEW_PATH']!)
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
  }, skip: !const bool.fromEnvironment('PUBLIC_UI_PREVIEW'));
}
