import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/core_bridge.dart';
import 'package:haptics_lab/main.dart';
import 'package:haptics_lab/model_provider.dart';

class PendingProvider extends ModelProvider {
  final result = Completer<ModelReply>();
  bool cancelled = false;
  ChatContext? context;
  @override
  void cancel() => cancelled = true;
  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) {
    this.context = context;
    return result.future;
  }
}

Future<void> openSettings(WidgetTester tester, PendingProvider provider) async {
  tester.view.physicalSize = const Size(1280, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  CoreBridge().call({'op': 'reset_simulation'});
  await tester.pumpWidget(
    HapticsApp(
      waveformDirectory: () async =>
          throw const FileSystemException('session storage'),
      modelProviderFactory: () => provider,
    ),
  );
  await tester.ensureVisible(find.text('模型与对话设置'));
  await tester.pump();
  await tester.tap(find.text('模型与对话设置'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const Key('model_source')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('model_source')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('通用 API（Chat Completions）').last);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const Key('test_model')));
  await tester.pump();
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets('stop cancels connection test and ignores its late reply', (
    tester,
  ) async {
    final provider = PendingProvider();
    await openSettings(tester, provider);
    await tester.tap(find.byKey(const Key('test_model')));
    await tester.pump();
    expect(provider.context?.controlAllowed, false);
    expect(find.textContaining('正在测试'), findsOneWidget);
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump();
    expect(provider.cancelled, true);
    expect(find.text('连接测试已取消，可重新测试。'), findsOneWidget);
    expect(find.textContaining('正在测试'), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('test_model')))
          .onPressed,
      isNotNull,
    );
    provider.result.complete(const ModelReply('迟到的回复', {'action': 'noop'}));
    await tester.pump();
    expect(find.textContaining('迟到的回复'), findsNothing);
    expect(CoreBridge().call({'op': 'snapshot'})['state']['output'], [
      0.0,
      0.0,
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('editing API configuration clears a previous connection result', (
    tester,
  ) async {
    final provider = PendingProvider();
    await openSettings(tester, provider);
    await tester.tap(find.byKey(const Key('test_model')));
    provider.result.complete(const ModelReply('已连接测试接口', {'action': 'noop'}));
    await tester.pump();
    expect(find.text('连接成功：已连接测试接口'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('model_name')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('model_name')),
      'a-different-model',
    );
    await tester.pump();
    expect(find.byKey(const Key('model_test_status')), findsNothing);
    expect(CoreBridge().call({'op': 'snapshot'})['state']['output'], [
      0.0,
      0.0,
    ]);
    await tester.pumpWidget(const SizedBox());
  });
}
