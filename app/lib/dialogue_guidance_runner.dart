import 'dart:async';

import 'dialogue_guidance.dart';
import 'model_provider.dart';
import 'network_diagnostics.dart';

/// Schedule a deadline and return a function that cancels it. Tests can inject
/// a manual scheduler without sleeping or depending on the provider finishing.
typedef GuidanceTimeoutScheduler = void Function() Function(
  Duration delay,
  void Function() onTimeout,
);

/// Optional dialogue advice, with no access to device state or authorization.
///
/// Closing the phone's connection does not prove that a relay has released its
/// upstream request. After an uncertain terminal state, a short cooldown keeps
/// this runner from accumulating more remote requests. The caller can also use
/// [networkMayStillBeBusy] to avoid overlapping streaming chat with TTS.
class DialogueGuidanceRunner {
  DialogueGuidanceRunner({
    DateTime Function()? now,
    this.timeout = dialogueGuidanceTimeout,
    this.cooldown = const Duration(seconds: 35),
    this.onDiagnostic,
    GuidanceTimeoutScheduler? scheduleTimeout,
  }) : _now = now ?? DateTime.now,
       _scheduleTimeout = scheduleTimeout ?? _defaultSchedule {
    if (timeout <= Duration.zero || cooldown <= Duration.zero) {
      throw ArgumentError('Guidance timeout and cooldown must be positive.');
    }
  }

  final Duration timeout, cooldown;
  final DateTime Function() _now;
  final void Function(String)? onDiagnostic;
  final GuidanceTimeoutScheduler _scheduleTimeout;
  _GuidanceRequest? _active;
  DateTime? _cooldownUntil;

  bool get isRunning => _active != null;

  /// True while a request is active, or its remote completion remains unknown.
  /// Expiry is evaluated lazily using the injected clock; no cooldown timer is
  /// needed, and late callbacks never clear or extend another request's state.
  bool get networkMayStillBeBusy =>
      isRunning || (_cooldownUntil != null && _now().isBefore(_cooldownUntil!));

  static void Function() _defaultSchedule(
    Duration delay,
    void Function() onTimeout,
  ) {
    final timer = Timer(delay, onTimeout);
    return timer.cancel;
  }

  void _log(String message, {NetworkTrace? trace}) {
    try {
      if (onDiagnostic != null) {
        onDiagnostic!(message);
      } else {
        (trace ?? NetworkTrace('对话导答')).mark(message);
      }
    } catch (_) {
      // Diagnostics must never interrupt the conversation or leak exceptions.
    }
  }

  Future<DialogueGuidance?> run(
    String input, {
    required ModelProvider Function() createProvider,
  }) {
    if (isRunning) {
      _log('state=skipped_busy input_chars=${input.length}');
      return Future.value(null);
    }
    if (networkMayStillBeBusy) {
      _log(
        'state=skipped_cooldown input_chars=${input.length} '
        'cooldown_remaining_ms=${_cooldownUntil!.difference(_now()).inMilliseconds}',
      );
      return Future.value(null);
    }

    final trace = onDiagnostic == null ? NetworkTrace('对话导答') : null;
    final ModelProvider provider;
    try {
      provider = createProvider();
    } catch (_) {
      // No request was started, so no remote connection can be left behind.
      _log('state=factory_failed input_chars=${input.length}', trace: trace);
      return Future.value(null);
    }
    final request = _GuidanceRequest(provider, _now(), input.length, trace);
    _active = request;
    _log('state=started input_chars=${input.length}', trace: trace);
    try {
      request.cancelTimeout = _scheduleTimeout(
        timeout,
        () => _finish(request, null, 'timeout', uncertain: true),
      );
    } catch (_) {
      _finish(request, null, 'scheduler_failed');
      return request.result.future;
    }
    // An injected scheduler may invoke its callback synchronously.
    if (!identical(_active, request)) {
      request.cancelTimeout?.call();
      return request.result.future;
    }
    unawaited(
      Future<ModelReply>.sync(() => provider.respond(input, '')).then<void>(
        (reply) {
          if (!identical(_active, request)) {
            _log(
              'state=late_result_discarded output_chars=${reply.text.length}',
              trace: trace,
            );
            return;
          }
          try {
            final guidance = DialogueGuidance.decode(reply.text);
            _finish(
              request,
              guidance,
              'success',
              outputChars: reply.text.length,
            );
          } catch (_) {
            // The full response arrived: invalid JSON is not an orphan socket.
            _finish(request, null, 'invalid', outputChars: reply.text.length);
          }
        },
        onError: (Object _, StackTrace _) {
          if (!identical(_active, request)) {
            _log('state=late_failure_discarded', trace: trace);
            return;
          }
          // ModelProvider does not establish whether a thrown error occurred
          // before upload, after a complete response, or mid-transport.
          _finish(request, null, 'failed', uncertain: true);
        },
      ),
    );
    return request.result.future;
  }

  /// Complete the waiter immediately; never wait for provider cancellation.
  /// This affects only this runner's current optional guidance request.
  void cancel() {
    final request = _active;
    if (request != null) {
      _finish(request, null, 'cancelled', uncertain: true);
    }
  }

  void _finish(
    _GuidanceRequest request,
    DialogueGuidance? guidance,
    String state, {
    bool uncertain = false,
    int outputChars = 0,
  }) {
    if (!identical(_active, request)) return;
    _active = null;
    request.cancelTimeout?.call();
    final now = _now();
    if (uncertain) _cooldownUntil = now.add(cooldown);
    final elapsed = now.difference(request.started).inMilliseconds;
    _log(
      'state=$state elapsed_ms=${elapsed < 0 ? 0 : elapsed} '
      'input_chars=${request.inputChars} output_chars=$outputChars '
      'cooldown_remaining_ms=${uncertain ? cooldown.inMilliseconds : 0}',
      trace: request.trace,
    );
    request.result.complete(guidance);
    if (uncertain) {
      try {
        request.provider.cancel();
      } catch (_) {
        _log('state=provider_cancel_failed', trace: request.trace);
      }
    }
  }
}

class _GuidanceRequest {
  _GuidanceRequest(this.provider, this.started, this.inputChars, this.trace);
  final ModelProvider provider;
  final DateTime started;
  final int inputChars;
  final NetworkTrace? trace;
  final result = Completer<DialogueGuidance?>();
  void Function()? cancelTimeout;
}
