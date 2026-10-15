import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'pilot_access_codes.dart';

enum AppRole { user, administrator }

typedef PilotAccessVerifier = bool Function(AppRole role, String credential);

enum PilotAccessAttempt { accepted, rejected, locked }

/// Local pilot access only: no credentials or login sessions are persisted.
bool verifyPilotCredential(
  AppRole role,
  String credential, {
  List<String>? userCodeHashes,
  String adminCodeHash = pilotAdminCodeHash,
}) {
  final normalized = role == AppRole.user
      ? credential.trim().toUpperCase()
      : credential.trim();
  if (role == AppRole.user && !RegExp(r'^[A-Z0-9]{10}$').hasMatch(normalized)) {
    return false;
  }
  if (normalized.isEmpty) return false;
  final digest = sha256.convert(utf8.encode(normalized)).toString();
  final candidates = role == AppRole.administrator
      ? [adminCodeHash]
      : (userCodeHashes ?? pilotUserCodeHashes);
  var matched = 0;
  for (final expected in candidates) {
    var difference = digest.length ^ expected.length;
    for (var index = 0; index < digest.length; index++) {
      difference |=
          digest.codeUnitAt(index) ^
          (index < expected.length ? expected.codeUnitAt(index) : 0);
    }
    matched |= difference == 0 ? 1 : 0;
  }
  return matched != 0;
}

/// Shared by both role tabs for one app session. Changing role never resets it.
class PilotAccessController {
  PilotAccessController({
    PilotAccessVerifier? verifier,
    DateTime Function()? now,
    this.maxFailures = 5,
    this.cooldown = const Duration(seconds: 30),
  }) : assert(maxFailures > 0),
       assert(cooldown > Duration.zero),
       _verifier = verifier ?? verifyPilotCredential,
       _now = now ?? DateTime.now;

  final PilotAccessVerifier _verifier;
  final DateTime Function() _now;
  final int maxFailures;
  final Duration cooldown;
  int _failures = 0;
  DateTime? _lockedUntil;

  int get failedAttempts => _failures;

  Duration get remaining {
    final until = _lockedUntil;
    if (until == null) return Duration.zero;
    final difference = until.difference(_now());
    return difference > Duration.zero ? difference : Duration.zero;
  }

  int get remainingSeconds => (remaining.inMilliseconds / 1000).ceil();

  PilotAccessAttempt attempt(AppRole role, String credential) {
    if (remaining > Duration.zero) return PilotAccessAttempt.locked;
    if (_lockedUntil != null) {
      _lockedUntil = null;
      _failures = 0;
    }
    bool valid;
    try {
      valid = _verifier(role, credential);
    } catch (_) {
      // An unavailable verifier never grants access or exposes its exception.
      valid = false;
    }
    if (valid) {
      _failures = 0;
      return PilotAccessAttempt.accepted;
    }
    _failures++;
    if (_failures >= maxFailures) {
      _lockedUntil = _now().add(cooldown);
      return PilotAccessAttempt.locked;
    }
    return PilotAccessAttempt.rejected;
  }
}
