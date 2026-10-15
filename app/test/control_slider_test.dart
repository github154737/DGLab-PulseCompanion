import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/control_slider.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('$platform slider accessibility, keyboard and drag commit', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        var value = 0.5;
        final commits = <double>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) => ControlSlider(
                  value: value,
                  divisions: 10,
                  onChanged: (v) => update(() => value = v),
                  onChangeEnd: commits.add,
                ),
              ),
            ),
          ),
        );
        final node = tester.getSemantics(find.byType(ControlSlider));
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.increase),
          true,
        );
        expect(node.getSemanticsData().value, '50%');
        node.owner!.performAction(node.id, ui.SemanticsAction.increase);
        await tester.pump();
        expect(value, closeTo(0.6, 0.00001));
        expect(commits, [0.6]);
        final focus = tester.widget<Focus>(
          find
              .descendant(
                of: find.byType(ControlSlider),
                matching: find.byType(Focus),
              )
              .first,
        );
        focus.focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(value, closeTo(0.5, 0.00001));
        expect(commits.length, 2);
        expect(find.byType(CupertinoSlider), findsOneWidget);
        await tester.drag(find.byType(CupertinoSlider), const Offset(120, 0));
        await tester.pumpAndSettle();
        expect(value, greaterThan(0.5));
        expect(commits.length, 3);
        expect(commits.last, value);
        expect(tester.takeException(), isNull);
      } finally {
        handle.dispose();
      }
    });
    testWidgets('disabled $platform slider exposes no increment action', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: const Scaffold(
              body: ControlSlider(value: 0.5, onChanged: null),
            ),
          ),
        );
        final data = tester
            .getSemantics(find.byType(ControlSlider))
            .getSemanticsData();
        expect(data.value, '50%');
        expect(data.hasAction(ui.SemanticsAction.increase), false);
        expect(data.hasAction(ui.SemanticsAction.decrease), false);
      } finally {
        handle.dispose();
      }
    });
  }
}
