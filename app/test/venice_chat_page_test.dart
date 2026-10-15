import 'package:haptics_lab/app_access.dart';

import 'warm_test_helpers.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/venice_chat_page.dart';

void main() {
  testWidgets(
    'opening Venice page only loads local key; send starts disabled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: VeniceChatPage(
            role: AppRole.administrator,
            enableDialogueGuidance: false,
            loadKey: () async {
              loads++;
              return 'fixture-private-secret';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(find.textContaining('fixture-private-secret'), findsNothing);
      expect(find.textContaining('fixture-private-secret'), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('venice_send')))
            .onPressed,
        isNull,
      );
      await tapWarm(tester, 'venice_funded');
      await tapWarm(tester, 'nav_chat');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('venice_send')))
            .onPressed,
        isNotNull,
      );
      expect(find.textContaining('fixture-private-secret'), findsNothing);
    },
  );
}
