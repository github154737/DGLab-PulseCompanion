import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

String secretToken() =>
    base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256)));
String digest(String value) => sha256.convert(utf8.encode(value)).toString();

/// One process owns this store. Every mutation is serialized and atomically renamed.
/// Access tokens and invitation codes are stored only as hashes.
class AccessStore {
  AccessStore(this.file, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final File file;
  final DateTime Function() clock;
  RandomAccessFile? _lock;
  Future<void> _queue = Future.value();
  Map<String, dynamic> data = {
    'version': 1,
    'invites': <String, dynamic>{},
    'users': <String, dynamic>{},
    'budget': 1000000,
    'used': 0,
    'input_tokens': 0,
    'output_tokens': 0,
    'input_price': 0.0,
    'output_price': 0.0,
  };
  Map<String, dynamic> get users => data['users'] as Map<String, dynamic>;
  Map<String, dynamic> get invites => data['invites'] as Map<String, dynamic>;
  Future<void> open() async {
    await file.parent.create(recursive: true);
    _lock = await File('${file.path}.lock').open(mode: FileMode.append);
    await _lock!.lock(FileLock.exclusive);
    try {
      if (await file.exists()) {
        final saved =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (saved['version'] != 1 ||
            saved['users'] is! Map ||
            saved['invites'] is! Map) {
          throw const FormatException('store_invalid');
        }
        data = saved;
      }
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<T> transaction<T>(T Function() work) {
    final result = Completer<T>();
    _queue = _queue.catchError((Object _) {}).then((_) async {
      final before = jsonEncode(data);
      try {
        final value = work();
        final temporary = File('${file.path}.pending');
        await temporary.writeAsString(jsonEncode(data), flush: true);
        await temporary.rename(file.path);
        result.complete(value);
      } catch (e, st) {
        data = jsonDecode(before) as Map<String, dynamic>;
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  Future<List<Map<String, String>>> createInvites(int count) => transaction(() {
    final live = invites.values.where((v) => v['revoked'] != true).length;
    if (count < 1 || live + count > 5) throw StateError('five_seat_limit');
    return List.generate(count, (_) {
      final id = secretToken().substring(0, 12), code = secretToken();
      invites[id] = {'hash': digest(code), 'revoked': false, 'user': null};
      return {'id': id, 'code': code};
    });
  });
  Future<Map<String, dynamic>> redeem(String code) => transaction(() {
    if (code.startsWith('restore.')) {
      final token = code.substring(8), id = authenticate(code.substring(8));
      if (id == null) throw StateError('invalid_recovery');
      return {'user': id, 'token': token, 'expires': users[id]['expires']};
    }
    if (code.length > 128) throw StateError('invalid_invite');
    final matches = invites.entries.where(
      (e) =>
          e.value['hash'] == digest(code) &&
          e.value['revoked'] == false &&
          e.value['user'] == null,
    );
    if (matches.length != 1 ||
        users.keys.where((id) => id != 'local-owner').length >= 5) {
      throw StateError('invalid_invite');
    }
    final entry = matches.single,
        id = secretToken().substring(0, 16),
        token = secretToken();
    final expires = clock()
        .add(const Duration(days: 30))
        .millisecondsSinceEpoch;
    users[id] = {
      'token_hash': digest(token),
      'expires': expires,
      'paused': false,
      'quota': 200000,
      'used': 0,
      'input_tokens': 0,
      'output_tokens': 0,
    };
    entry.value['user'] = id;
    return {'user': id, 'token': token, 'expires': expires};
  });
  String? authenticate(String token) {
    if (token.length > 128 || token.length < 32) return null;
    final hash = digest(token);
    for (final entry in users.entries) {
      if (entry.value['token_hash'] == hash &&
          entry.value['paused'] == false &&
          entry.value['expires'] > clock().millisecondsSinceEpoch) {
        return entry.key;
      }
    }
    return null;
  }

  /// Local operator has a separate seat, but shares the service budget.
  Future<void> configureLocalOwner(String token) => transaction(() {
    if (token.length < 32) throw StateError('invalid_owner_token');
    users['local-owner'] = {
      ...?users['local-owner'] as Map<String, dynamic>?,
      'token_hash': digest(token),
      'expires': clock().add(const Duration(days: 30)).millisecondsSinceEpoch,
      'paused': false,
      'quota': 200000,
      'used': users['local-owner']?['used'] ?? 0,
      'input_tokens': users['local-owner']?['input_tokens'] ?? 0,
      'output_tokens': users['local-owner']?['output_tokens'] ?? 0,
    };
  });

  Future<Map<String, dynamic>> recover(String id) => transaction(() {
    final user = users[id];
    if (user == null) throw StateError('unknown_user');
    final token = secretToken();
    user['token_hash'] = digest(token);
    user['expires'] = clock()
        .add(const Duration(days: 30))
        .millisecondsSinceEpoch;
    return {'user': id, 'recovery_code': 'restore.$token'};
  });
  Map<String, dynamic> account(String id) {
    final u = users[id];
    if (u == null) throw StateError('unknown_user');
    return {
      'user': id,
      'paused': u['paused'],
      'quota': u['quota'],
      'used': u['used'],
      'expires': u['expires'],
    };
  }

  Future<void> manage(Map<String, dynamic> command) => transaction(() {
    switch (command['op']) {
      case 'revoke':
        final invite = invites[command['id']];
        if (invite == null) throw StateError('unknown_invite');
        invite['revoked'] = true;
        if (invite['user'] != null) users[invite['user']]['paused'] = true;
      case 'user':
        final user = users[command['id']];
        if (user == null) throw StateError('unknown_user');
        if (command['paused'] is bool) user['paused'] = command['paused'];
        if (command['quota'] is int &&
            command['quota'] >= 0 &&
            command['quota'] <= 100000000) {
          user['quota'] = command['quota'];
        }
      case 'budget':
        if (command['tokens'] is! int ||
            command['tokens'] < 0 ||
            command['tokens'] > 1000000000) {
          throw StateError('invalid_budget');
        }
        data['budget'] = command['tokens'];
        for (final name in ['input_price', 'output_price']) {
          if (command[name] != null) {
            final n = command[name];
            if (n is! num || !n.isFinite || n < 0 || n > 1000000) {
              throw StateError('invalid_price');
            }
            data[name] = n;
          }
        }
      default:
        throw StateError('invalid_operation');
    }
  });
  Future<void> reserve(String id, int tokens) => transaction(() {
    final u = users[id];
    if (u == null ||
        u['paused'] ||
        u['expires'] <= clock().millisecondsSinceEpoch) {
      throw StateError('access_denied');
    }
    if (u['used'] + tokens > u['quota'] ||
        data['used'] + tokens > data['budget']) {
      throw StateError('quota_exhausted');
    }
    // Charged before opening upstream; crash cannot reset the budget.
    u['used'] += tokens;
    data['used'] += tokens;
  });
  Future<void> settle(
    String id,
    int reserved,
    int used,
    int input,
    int output,
  ) => transaction(() {
    final u = users[id];
    final refund =
        reserved - used; // negative means provider exceeded reservation
    u['used'] -= refund;
    data['used'] -= refund;
    u['input_tokens'] += input;
    u['output_tokens'] += output;
    data['input_tokens'] += input;
    data['output_tokens'] += output;
  });
  Map<String, dynamic> summary() => {
    'invites': [
      for (final e in invites.entries)
        {
          'id': e.key,
          'revoked': e.value['revoked'],
          'redeemed': e.value['user'] != null,
          'user': e.value['user'],
        },
    ],
    'users': [for (final id in users.keys) account(id)],
    for (final k in [
      'budget',
      'used',
      'input_tokens',
      'output_tokens',
      'input_price',
      'output_price',
    ])
      k: data[k],
    'estimated_cost':
        (data['input_tokens'] * data['input_price'] +
            data['output_tokens'] * data['output_price']) /
        1000000,
    'cost_note': '按管理员填写的每百万 token 单价估算；多模态价格差异及账单以供应商为准；0 表示未配置价格',
  };
  Future<void> close() async {
    await _queue;
    await _lock?.unlock();
    await _lock?.close();
    _lock = null;
  }
}
