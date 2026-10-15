import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/dialogue_guidance_runner.dart';
import 'package:haptics_lab/model_provider.dart';

class _Provider extends ModelProvider {
  final result = Completer<ModelReply>();
  final inputs = <String>[];
  int cancellations = 0;
  bool throwOnCancel = false;

  @override
  Future<ModelReply> respond(
    String text,
    String alias, {
    ChatContext context = const ChatContext(),
  }) {
    inputs.add(text);
    return result.future;
  }

  @override
  void cancel() {
    cancellations++;
    if (throwOnCancel) throw StateError('private-cancel-error');
  }

  void succeed([String intent = '理解当前问题']) => result.complete(
    ModelReply(
      jsonEncode({
        'intent_summary': intent,
        'reply_focus': ['简短回应'],
        'context_anchor': '',
        'ask_clarification': false,
      }),
      const {'action': 'noop'},
    ),
  );
}

class _Deadline {
  _Deadline(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool cancelled = false;
  void fire() {
    if (!cancelled) callback();
  }
}

class _Fixture {
  DateTime time = DateTime(2026, 10, 15);
  final logs = <String>[];
  final deadlines = <_Deadline>[];
  late final runner = DialogueGuidanceRunner(
    now: () => time,
    onDiagnostic: logs.add,
    scheduleTimeout: (delay, callback) {
      final deadline = _Deadline(delay, callback);
      deadlines.add(deadline);
      return () => deadline.cancelled = true;
    },
  );

  void advance(Duration duration) => time = time.add(duration);
}

Future<void> _flushCallbacks() async {
  await Future<void>.value();
  await Future<void>.value();
}

void main() {
  test(
    'returns validated guidance and releases its timeout without cooldown',
    () async {
      final f = _Fixture();
      final provider = _Provider();
      final future = f.runner.run(
        '{"user_message":"请解释"}',
        createProvider: () => provider,
      );
      expect(f.runner.isRunning, true);
      expect(f.runner.networkMayStillBeBusy, true);
      expect(provider.inputs, ['{"user_message":"请解释"}']);
      expect(f.deadlines.single.delay, const Duration(seconds: 8));
      f.advance(const Duration(milliseconds: 120));
      provider.succeed();
      final guidance = await future;
      expect(guidance!.intentSummary, '理解当前问题');
      expect(f.runner.isRunning, false);
      expect(f.runner.networkMayStillBeBusy, false);
      expect(f.deadlines.single.cancelled, true);
      expect(provider.cancellations, 0);
      expect(f.logs.last, contains('elapsed_ms=120'));
      expect(f.logs.last, contains('state=success'));
    },
  );

  test(
    'completed invalid JSON falls back without a network cooldown',
    () async {
      final f = _Fixture();
      final provider = _Provider();
      final future = f.runner.run('{}', createProvider: () => provider);
      provider.result.complete(const ModelReply('private-invalid-json', {}));
      expect(await future, isNull);
      expect(f.runner.networkMayStillBeBusy, false);
      expect(provider.cancellations, 0);
      expect(f.logs.last, contains('state=invalid'));
      expect(f.logs.join(), isNot(contains('private-invalid-json')));
    },
  );

  test('factory failure never starts a request or enters cooldown', () async {
    final f = _Fixture();
    expect(
      await f.runner.run(
        '{}',
        createProvider: () => throw StateError('private-factory-secret'),
      ),
      isNull,
    );
    expect(f.runner.isRunning, false);
    expect(f.runner.networkMayStillBeBusy, false);
    expect(f.deadlines, isEmpty);
    expect(f.logs.single, contains('state=factory_failed'));
    expect(f.logs.join(), isNot(contains('private-factory-secret')));
  });

  test(
    'timeout actively cancels and completes despite an unresponsive provider',
    () async {
      final f = _Fixture();
      final provider = _Provider();
      final future = f.runner.run('{}', createProvider: () => provider);
      f.advance(const Duration(seconds: 8));
      f.deadlines.single.fire();
      expect(await future, isNull);
      expect(provider.result.isCompleted, false);
      expect(provider.cancellations, 1);
      expect(f.runner.isRunning, false);
      expect(f.runner.networkMayStillBeBusy, true);
      expect(f.logs.last, contains('state=timeout'));
      expect(f.logs.last, contains('cooldown_remaining_ms=35000'));
    },
  );

  test('explicit cancellation finishes the waiter and is idempotent', () async {
    final f = _Fixture();
    final provider = _Provider();
    final future = f.runner.run('{}', createProvider: () => provider);
    f.runner.cancel();
    expect(await future, isNull);
    expect(provider.result.isCompleted, false);
    expect(provider.cancellations, 1);
    expect(f.deadlines.single.cancelled, true);
    expect(f.runner.networkMayStillBeBusy, true);
    f.runner.cancel();
    expect(provider.cancellations, 1);
  });

  test(
    'provider failure falls back, cancels, and starts conservative cooldown',
    () async {
      final f = _Fixture();
      final provider = _Provider();
      final future = f.runner.run('{}', createProvider: () => provider);
      provider.result.completeError(StateError('private-transport-secret'));
      expect(await future, isNull);
      expect(provider.cancellations, 1);
      expect(f.runner.networkMayStillBeBusy, true);
      expect(f.logs.last, contains('state=failed'));
      expect(f.logs.join(), isNot(contains('private-transport-secret')));
    },
  );

  test(
    'cooldown skips creation until expiry, then allows another request',
    () async {
      final f = _Fixture();
      final first = _Provider();
      final firstFuture = f.runner.run('{}', createProvider: () => first);
      f.runner.cancel();
      await firstFuture;
      var creations = 0;
      final next = _Provider();
      ModelProvider create() {
        creations++;
        return next;
      }

      f.advance(const Duration(seconds: 34));
      expect(await f.runner.run('{}', createProvider: create), isNull);
      expect(creations, 0);
      expect(f.logs.last, contains('cooldown_remaining_ms=1000'));
      f.advance(const Duration(seconds: 1));
      expect(f.runner.networkMayStillBeBusy, false);
      final nextFuture = f.runner.run('{}', createProvider: create);
      next.succeed('新的问题');
      expect((await nextFuture)!.intentSummary, '新的问题');
      expect(creations, 1);
    },
  );

  test(
    'a late old success cannot finish, cancel, or overwrite the next request',
    () async {
      final f = _Fixture();
      final old = _Provider();
      final oldFuture = f.runner.run('{}', createProvider: () => old);
      f.runner.cancel();
      expect(await oldFuture, isNull);
      f.advance(const Duration(seconds: 35));
      final next = _Provider();
      final nextFuture = f.runner.run('{}', createProvider: () => next);
      var nextCompleted = false;
      unawaited(nextFuture.then<void>((_) => nextCompleted = true));
      old.succeed('过期建议');
      await _flushCallbacks();
      expect(nextCompleted, false);
      expect(f.runner.isRunning, true);
      expect(next.cancellations, 0);
      expect(f.deadlines.last.cancelled, false);
      next.succeed('本轮建议');
      expect((await nextFuture)!.intentSummary, '本轮建议');
      expect(f.runner.networkMayStillBeBusy, false);
      expect(
        f.logs.any((line) => line.contains('late_result_discarded')),
        true,
      );
    },
  );

  test(
    'late failure is consumed without extending a previous cooldown',
    () async {
      final f = _Fixture();
      final provider = _Provider();
      final future = f.runner.run('{}', createProvider: () => provider);
      f.runner.cancel();
      await future;
      f.advance(const Duration(seconds: 36));
      provider.result.completeError(StateError('private-late-secret'));
      await _flushCallbacks();
      expect(f.runner.networkMayStillBeBusy, false);
      expect(f.logs.last, 'state=late_failure_discarded');
      expect(f.logs.join(), isNot(contains('private-late-secret')));
    },
  );

  test(
    'only one guidance request runs and a concurrent attempt cannot replace it',
    () async {
      final f = _Fixture();
      final first = _Provider();
      final firstFuture = f.runner.run('{}', createProvider: () => first);
      var otherCreated = false;
      expect(
        await f.runner.run(
          '{}',
          createProvider: () {
            otherCreated = true;
            return _Provider();
          },
        ),
        isNull,
      );
      expect(otherCreated, false);
      expect(first.cancellations, 0);
      expect(f.runner.isRunning, true);
      first.succeed();
      expect(await firstFuture, isNotNull);
    },
  );

  test(
    'diagnostics never contain raw input, model output, or cancellation errors',
    () async {
      final f = _Fixture();
      final success = _Provider();
      final successFuture = f.runner.run(
        '{"user_message":"private-input-secret"}',
        createProvider: () => success,
      );
      success.succeed('private-output-secret');
      await successFuture;
      final cancelled = _Provider()..throwOnCancel = true;
      final cancelledFuture = f.runner.run(
        '{}',
        createProvider: () => cancelled,
      );
      f.runner.cancel();
      expect(await cancelledFuture, isNull);
      final logs = f.logs.join('\n');
      expect(logs, isNot(contains('private-input-secret')));
      expect(logs, isNot(contains('private-output-secret')));
      expect(logs, isNot(contains('private-cancel-error')));
      expect(logs, contains('input_chars='));
      expect(logs, contains('output_chars='));
      expect(logs, contains('state=provider_cancel_failed'));
    },
  );
}
