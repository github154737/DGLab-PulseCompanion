// Stage A: owner-only, audio feasibility probe. No physical device adapter.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'simulation_session.dart';

typedef ProbeCore = Map<String, dynamic> Function(Map<String, dynamic>);
typedef ProbeEmit = void Function(Map<String, dynamic>);
typedef ProbeConnect = Future<WebSocket> Function(Uri, String);

class ProbeConfig {
  ProbeConfig(String host, this.key, {this.style = 'playful'}) {
    if (!probeStyles.containsKey(style)) {
      throw const FormatException('invalid_style');
    }
    final value = host.trim().replaceFirst(RegExp(r'^https://'), '');
    if (!RegExp(r'^[a-zA-Z0-9-]+\.cn-beijing\.maas\.aliyuncs\.com$')
        .hasMatch(value)) {
      throw const FormatException('请粘贴北京业务空间的 API Host（只含域名）');
    }
    if (key.length < 12 || key.length > 8192 || key.contains(RegExp(r'\s'))) {
      throw const FormatException('请填写有效的百炼 API Key');
    }
    uri = Uri(
      scheme: 'wss',
      host: value,
      path: '/api-ws/v1/realtime',
      queryParameters: {'model': model},
    );
  }
  static const model = 'qwen3.8-omni-flash-realtime';
  final String key;
  final String style;
  late final Uri uri;
}

Future<WebSocket> connectProbeSocket(Uri uri, String key) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  client.findProxy = (_) => 'DIRECT';
  var expired = false;
  final connection = WebSocket.connect(
    uri.toString(),
    headers: {'Authorization': 'Bearer $key'},
    customClient: client,
  );
  // A handshake completing after timeout must never leave a live connection.
  unawaited(
    connection.then((socket) {
      if (expired) unawaited(socket.close());
    }, onError: (Object _) {}),
  );
  try {
    return await connection.timeout(const Duration(seconds: 15));
  } finally {
    expired = true;
    client.close(force: true);
  }
}

const probeStyles = {
  'playful':
      '你是名叫小岚的AI语音伙伴，和成年用户进行自然、轻松、略带暧昧但不露骨的交流。'
      '语气亲近、俏皮，有一点点含蓄的打趣；认真接住用户上一句话，少用模板。'
      '不要用“有什么可以帮您”“作为测试助手”等客服开场，也不要每句都追问需求。'
      '用户简单打招呼时，可以回应“来啦，今天想慢慢聊，还是先让我逗你笑？”这样的轻松语气，但不要机械重复示例。'
      '称呼以用户偏好为准，不默认使用主人等角色称呼，不要求排他关系，不假装自己是真人。',
  'gentle':
      '你是名叫小岚的AI语音伙伴，语气温柔、亲近、自然，面向成年用户进行不露骨的陪伴交流。'
      '记住本会话的偏好，回应具体内容，偶尔轻松打趣。不要用客服式开场和反复确认，也不假装真人。',
  'technical': '你是中文实时语音技术测试助手，用简短、中性的语言解释测试结果。',
};

const probeSession = {
  'modalities': ['text', 'audio'],
  'voice': 'Tina',
  'input_audio_format': 'pcm',
  'output_audio_format': 'pcm',
  'input_audio_transcription': {'model': 'qwen3-asr-flash-realtime'},
  'turn_detection': {
    'type': 'server_vad',
    'threshold': 0.5,
    'prefix_padding_ms': 300,
    'silence_duration_ms': 600,
  },
  'max_tokens': 512,
  'instructions':
      '回复自然、简短，通常一到三句话，不把工具名、JSON或测试步骤念给用户。'
      '只连接虚拟模拟器。只有用户明确要求增强、减弱、换波形或停止时才调用 simulation_control。'
      '不要根据响度、笑声、沉默或猜测增强。否定、引用、犹豫和不确定语音不执行动作。'
      '不能授权、续期或连接实物。每次请求最多调用一个工具，不能自行重试被拒绝的动作。'
      '必须收到工具回执后才说明是否成功，不要在回执前声称已经改变。'
      '用户说停止或不舒服时调用 stop，无需任何称呼或额外条件。'
      '用户问声音特征时，只描述能听到的特征并承认不确定，不推断身体状态。',
  'tools': [
    {
      'type': 'function',
      'function': {
        'name': 'simulation_control',
        'description': '按用户明确指令控制已授权的虚拟波形；收到回执后再口头回应。',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'increase',
                'decrease',
                'stop',
                'gentle_wave',
                'soft_pulse',
              ],
            },
          },
          'required': ['action'],
          'additionalProperties': false,
        },
      },
    },
  ],
};

class _Turn {
  _Turn(this.ticket, this.generation, this.followup);
  final int? ticket;
  final int generation;
  final bool followup;
  final calls = <String, Map<String, dynamic>>{};
}

class RealtimeProbe {
  RealtimeProbe(this.core, this.emit, {ProbeConnect? connect})
    : connect = connect ?? connectProbeSocket;
  final ProbeCore core;
  final ProbeEmit emit;
  final ProbeConnect connect;
  SimulationSession? autonomous;
  String roleContext = '';
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _ready;
  Timer? _maximum;
  bool ready = false, connecting = false, _speaking = false;
  String style = 'playful';
  bool _expectResponse = false;
  bool get busy => _speaking || _expectResponse || _turns.isNotEmpty;
  bool _pendingFollowup = false;
  int _generation = 0, _connectionGeneration = 0;
  int? _pendingTicket;
  final _turns = <String, _Turn>{};
  final _seenResponses = <String>{}, _seenCalls = <String>{};
  final Map<String, int> counts = {};
  final List<int> firstAudioMs = [];
  final List<Map<String, dynamic>> lifecycle = [], receipts = [];
  final Set<String> _cancelEvents = {};
  int _eventSequence = 0;
  DateTime? _speechEnded;
  String status = '尚未连接';
  void count(String name) => counts[name] = (counts[name] ?? 0) + 1;
  void record(String code) {
    lifecycle.add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'event': code,
    });
    if (lifecycle.length > 80) lifecycle.removeAt(0);
  }

  Map<String, dynamic> get state {
    final s = core({'op': 'snapshot'})['state'] as Map<String, dynamic>;
    return {
      'type': 'state',
      'ready': ready,
      'connecting': connecting,
      'status': status,
      'style': style,
      'simulation_only': true,
      for (final name in [
        'phase',
        'gain',
        'gain_target',
        'output',
        'preset',
        'remaining_ms',
      ])
        name: s[name],
    };
  }

  Future<void> start(ProbeConfig config) => startConnection(
    () => connect(config.uri, config.key),
    selectedStyle: config.style,
  );

  Future<void> startConnection(
    Future<WebSocket> Function() open, {
    String selectedStyle = 'playful',
  }) async {
    if (!probeStyles.containsKey(selectedStyle)) {
      throw const FormatException('invalid_style');
    }
    if (ready || connecting) throw StateError('会话已经连接或正在连接');
    final epoch = ++_connectionGeneration;
    connecting = true;
    status = '正在连接百炼';
    counts.clear();
    firstAudioMs.clear();
    lifecycle.clear();
    receipts.clear();
    _cancelEvents.clear();
    style = selectedStyle;
    record('connect_started');
    _seenResponses.clear();
    _seenCalls.clear();
    _ready = Completer<void>();
    // Observe errors immediately, even if a handshake fails before awaiting it.
    unawaited(_ready!.future.then((_) {}, onError: (Object _) {}));
    try {
      final socket = await open();
      if (epoch != _connectionGeneration) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 10);
      _subscription = socket.listen(
        (raw) {
          if (epoch != _connectionGeneration) return;
          try {
            if (raw is! String || raw.length > 1024 * 1024) {
              throw const FormatException('event_size');
            }
            handle(jsonDecode(raw) as Map<String, dynamic>);
          } catch (_) {
            fail('服务事件格式异常，会话已停止', reason: 'provider_event_format');
          }
        },
        onError: (Object _) {
          if (epoch == _connectionGeneration) {
            fail('实时连接发生错误', reason: 'provider_transport_error');
          }
        },
        onDone: () {
          if (epoch == _connectionGeneration) {
            fail('实时连接已断开', reason: 'provider_disconnected');
          }
        },
      );
      send({
        'type': 'session.update',
        'session': {
          ...probeSession,
          'instructions':
              '${probeStyles[style]}${probeSession['instructions']}'
              '${roleContext.length <= 2000 ? roleContext : ''}'
              '${autonomous == null ? '' : autonomousInstructions}',
          if (autonomous != null)
            'tools': [...probeSession['tools'] as List, autonomousTool],
        },
      });
      await _ready!.future.timeout(const Duration(seconds: 12));
      if (epoch != _connectionGeneration) return;
      ready = true;
      connecting = false;
      status = '已连接 · 麦克风尚未开启';
      record('connected');
      _maximum = Timer(
        const Duration(minutes: 3),
        () => fail('本轮三分钟测试已结束 · 可直接重连', reason: 'session_limit'),
      );
      emit(state);
    } catch (_) {
      if (epoch == _connectionGeneration) {
        await close(
          message: '连接失败：请检查密钥、北京 API Host、模型权限和额度',
          reason: 'connect_failed',
        );
      }
      rethrow;
    }
  }

  void send(Map<String, dynamic> event) {
    if (_socket?.readyState == WebSocket.open) {
      final eventId = 'probe_${++_eventSequence}';
      if (event['type'] == 'response.cancel') {
        _cancelEvents.add(eventId);
        if (_cancelEvents.length > 20) {
          _cancelEvents.remove(_cancelEvents.first);
        }
      }
      _socket!.add(jsonEncode({...event, 'event_id': eventId}));
    }
  }

  void appendAudio(List<int> bytes) {
    if (!ready || bytes.isEmpty || bytes.length > 32000 || bytes.length.isOdd) {
      return;
    }
    count('input_audio_chunks');
    send({'type': 'input_audio_buffer.append', 'audio': base64Encode(bytes)});
  }

  void _cancelTicket(int? ticket) {
    if (ticket != null) core({'op': 'cancel_ai', 'ticket': ticket});
  }

  void interrupt({bool clearInput = false}) {
    _generation++;
    if (_turns.isNotEmpty) send({'type': 'response.cancel'});
    for (final turn in _turns.values) {
      _cancelTicket(turn.ticket);
    }
    _turns.clear();
    _cancelTicket(_pendingTicket);
    _pendingTicket = null;
    _expectResponse = false;
    _pendingFollowup = false;
    _speechEnded = null;
    if (clearInput) {
      _speaking = false;
      send({'type': 'input_audio_buffer.clear'});
    }
    emit({'type': 'interrupt'});
  }

  Map<String, dynamic> grant() {
    if (!ready) return {'ok': false, 'error': 'voice_not_ready'};
    interrupt(clearInput: true);
    core({'op': 'stop'});
    core({'op': 'connect', 'device_id': 'sim_single'});
    core({'op': 'set_ai_control', 'enabled': true});
    final result = core({'op': 'authorize', 'limit': 0.3, 'lease_ms': 30000});
    if (result['ok'] == true) {
      core({'op': 'start_experience', 'preset_id': 'gentle_wave'});
      count('local_grants');
    }
    emit(state);
    return {
      'ok': result['ok'],
      if (result['error'] != null) 'error': result['error'],
    };
  }

  void stopOutput() {
    autonomous?.stop();
    interrupt(clearInput: true);
    core({'op': 'stop'});
    count('local_stops');
    emit(state);
  }

  void pause() {
    stopOutput();
    record('capture_paused');
    status = ready ? '已暂停采集与模拟输出 · 语音连接保留' : status;
    emit(state);
  }

  void handle(Map<String, dynamic> event) {
    final type = event['type'];
    if (type == 'service.heartbeat') {
      emit({'type': 'service.heartbeat'});
      return;
    }
    if (type == 'service.closed') {
      final reason = event['reason'];
      fail(
        '语音服务已结束：${['access_revoked', 'session_limit', 'quota_exhausted', 'provider_error', 'service_shutdown'].contains(reason) ? reason : 'connection_closed'}',
        reason: 'service_closed',
      );
      return;
    }
    if (type == 'session.updated') {
      count('session_updated');
      if (_ready?.isCompleted == false) _ready!.complete();
      return;
    }
    if (type == 'error') {
      final error = event['error'];
      if (error is Map &&
          _cancelEvents.remove(error['event_id']) &&
          RegExp(
            r'no active response|no response.*cancel|response.*already.*(completed|cancelled)',
            caseSensitive: false,
          ).hasMatch(
            error['message'] is String ? error['message'] as String : '',
          )) {
        count('cancel_race_ignored');
        record('cancel_race_ignored');
        return;
      }
      // Never expose upstream messages: they can echo headers or user text.
      fail('百炼返回错误，请检查模型权限、额度或会话参数');
      return;
    }
    if (type == 'input_audio_buffer.speech_started') {
      autonomous?.feedback();
      count('speech_started');
      interrupt();
      _speaking = true;
      emit({'type': 'speech', 'active': true});
      return;
    }
    if (type == 'input_audio_buffer.speech_stopped') {
      if (!_speaking) return;
      _speaking = false;
      _expectResponse = true;
      _pendingTicket = core({'op': 'begin_ai'})['result']?['ticket'] as int?;
      _speechEnded = DateTime.now();
      emit({'type': 'speech', 'active': false});
      return;
    }
    if (type == 'conversation.item.input_audio_transcription.completed') {
      final transcript = event['transcript'];
      if (transcript is String &&
          RegExp(
            r'停止|停下|不要了|不舒服|^停$|^stop$',
            caseSensitive: false,
          ).hasMatch(transcript.trim())) {
        stopOutput();
      }
      count('input_transcripts');
      emit({
        'type': 'transcript',
        'speaker': 'user',
        'text': event['transcript'],
      });
      return;
    }
    if (type == 'conversation.item.input_audio_transcription.failed') {
      count('transcription_failures');
      stopOutput();
      return;
    }
    if (type == 'response.created') {
      final id = event['response']?['id'];
      if (id is! String || _seenResponses.contains(id)) return;
      if (_seenResponses.length >= 100) {
        fail('本轮回合数量已达上限');
        return;
      }
      _seenResponses.add(id);
      if (!_expectResponse || _speaking) {
        count('stale_responses');
        send({'type': 'response.cancel'});
        return;
      }
      _expectResponse = false;
      _turns[id] = _Turn(_pendingTicket, _generation, _pendingFollowup);
      _pendingFollowup = false;
      _pendingTicket = null;
      count('responses');
      return;
    }
    final id = type == 'response.done'
        ? (event['response']?['id'])
        : event['response_id'];
    final turn = _turns[id];
    if (turn == null || turn.generation != _generation) return;
    if (type == 'response.audio.delta') {
      if (_speechEnded != null) {
        firstAudioMs.add(
          DateTime.now().difference(_speechEnded!).inMilliseconds,
        );
        _speechEnded = null;
      }
      count('output_audio_chunks');
      emit({'type': 'audio', 'data': event['delta']});
    } else if (type == 'response.audio_transcript.done' ||
        type == 'response.text.done') {
      emit({
        'type': 'transcript',
        'speaker': 'assistant',
        'text': event['transcript'] ?? event['text'],
      });
    } else if (type == 'response.function_call_arguments.done') {
      final callId = event['call_id'];
      if (callId is String && !turn.calls.containsKey(callId)) {
        if (turn.calls.length >= 4) {
          fail('模型工具调用数量异常');
          return;
        }
        turn.calls[callId] = event;
      }
    } else if (type == 'response.done') {
      _turns.remove(id);
      if (event['response']?['status'] != 'completed') {
        _cancelTicket(turn.ticket);
        count('incomplete_responses');
        return;
      }
      var hasReceipt = false;
      for (final entry in turn.calls.entries) {
        if (!_seenCalls.add(entry.key)) {
          count('duplicate_calls');
          continue;
        }
        final result = _execute(turn, entry.value, turn.calls.length == 1);
        count(result['ok'] == true ? 'accepted_tools' : 'rejected_tools');
        receipts.add({
          'at': DateTime.now().toUtc().toIso8601String(),
          ...result,
        });
        if (receipts.length > 40) receipts.removeAt(0);
        emit({'type': 'receipt', ...result});
        send({
          'type': 'conversation.item.create',
          'item': {
            'type': 'function_call_output',
            'call_id': entry.key,
            'output': jsonEncode(result),
          },
        });
        hasReceipt = true;
      }
      _cancelTicket(turn.ticket);
      if (hasReceipt) {
        // Tool continuation gets no ticket. It may explain but never chain actions.
        if (!turn.followup) {
          _expectResponse = true;
          _pendingTicket = null;
          _pendingFollowup = true;
          send({'type': 'response.create'});
        }
      }
      final usage = event['response']?['usage'];
      if (usage is Map) {
        for (final key in ['input_tokens', 'output_tokens', 'total_tokens']) {
          final value = usage[key];
          if (value is int && value >= 0) {
            counts[key] = (counts[key] ?? 0) + value;
          }
        }
      }
    }
  }

  Map<String, dynamic> _execute(
    _Turn turn,
    Map<String, dynamic> event,
    bool single,
  ) {
    Map<String, dynamic> rejected(String code) => {
      'ok': false,
      'error': code,
      'simulation_only': true,
    };
    if (!single || event['name'] != 'simulation_control') {
      if (single &&
          event['name'] == 'simulation_plan' &&
          autonomous != null &&
          !turn.followup) {
        try {
          final args = jsonDecode(event['arguments'] as String);
          if (args is Map && args.length == 1) {
            return autonomous!.schedule(args['steps'], turn.ticket);
          }
        } catch (_) {}
      }
      return rejected('unsupported_tool');
    }
    try {
      final args = jsonDecode(event['arguments'] as String);
      if (args is! Map || args.length != 1) {
        return rejected('invalid_arguments');
      }
      final action = args['action'];
      if (![
        'increase',
        'decrease',
        'stop',
        'gentle_wave',
        'soft_pulse',
      ].contains(action)) {
        return rejected('invalid_action');
      }
      if (action == 'stop') {
        autonomous?.stop();
        final stopped = core({'op': 'stop'});
        return {
          'ok': stopped['ok'],
          'action': 'stop',
          'simulation_only': true,
          'gain_target': stopped['state']['gain_target'],
          'output': stopped['state']['output'],
          'phase': stopped['state']['phase'],
        };
      }
      if (turn.ticket == null) return rejected('not_authorized_or_followup');
      final before = core({'op': 'snapshot'})['state']['gain_target'] as num;
      final intent = ['increase', 'decrease'].contains(action)
          ? {
              'action': 'set_gain',
              'gain': (before + (action == 'increase' ? 0.1 : -0.1)).clamp(
                0.0,
                autonomous?.active == true ? autonomous!.gainCeiling : 1.0,
              ),
            }
          : {
              'action': 'play_preset',
              'device_alias': 'sim_single',
              'preset_id': action,
            };
      final result = core({
        'op': 'complete_ai',
        'ticket': turn.ticket,
        'response': jsonEncode(intent),
      });
      return {
        'ok': result['ok'],
        'action': action,
        'simulation_only': true,
        if (result['error'] != null) 'error': result['error'],
        'gain_before': before,
        'gain_target': result['state']['gain_target'],
      };
    } catch (_) {
      return rejected('invalid_arguments');
    }
  }

  Map<String, dynamic> report() => {
    'schema': 'voice-probe-2',
    'created_at': DateTime.now().toUtc().toIso8601String(),
    'model': ProbeConfig.model,
    'simulation_only': true,
    'counts': Map<String, int>.from(counts),
    'style': style,
    'lifecycle': List<Map<String, dynamic>>.from(lifecycle),
    'receipts': List<Map<String, dynamic>>.from(receipts),
    'speech_end_to_first_audio_received_ms': List<int>.from(firstAudioMs),
    'physical_device_verified': false,
    'human_audio_quality_verified': false,
    'sound_understanding_verified': false,
    'adult_scenario_suitability_verified': false,
    'note': '接收时延不等于扬声器播放时延；计数不代表语义正确。未保存密钥、域名、音频、转写或聊天正文。',
  };

  /// Text feedback and locally initiated planning share the same turn barrier.
  void requestText(String text, {bool automatic = false}) {
    if (!ready || text.isEmpty || text.length > 2000) return;
    if (!automatic) autonomous?.feedback();
    interrupt(clearInput: true);
    _pendingTicket = core({'op': 'begin_ai'})['result']?['ticket'] as int?;
    _expectResponse = true;
    send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': text},
        ],
      },
    });
    send({'type': 'response.create'});
  }

  void requestPlan() {
    if (autonomous?.active != true) return;
    requestText(
      '本地用户已授权自主模拟，剩余 ${autonomous!.remaining} 秒，相对强度上限 ${autonomous!.gainCeiling}。请主动安排不超过30秒的有界计划，使用 simulation_plan。只有回执确认后才能说已执行。',
      automatic: true,
    );
  }

  void fail(String message, {String reason = 'provider_or_session_error'}) {
    unawaited(close(message: message, reason: reason));
  }

  Future<void> close({
    String message = '已断开语音 · 麦克风已停止',
    String reason = 'user_disconnect',
  }) async {
    record(reason);
    ++_connectionGeneration;
    ready = false;
    connecting = false;
    _maximum?.cancel();
    _maximum = null;
    interrupt(clearInput: true);
    autonomous?.stop();
    core({'op': 'stop'});
    status = message;
    if (_ready?.isCompleted == false) {
      _ready!.completeError(StateError('closed'));
    }
    _ready = null;
    final socket = _socket;
    _socket = null;
    final subscription = _subscription;
    _subscription = null;
    emit({'type': 'closed', 'message': message});
    await subscription?.cancel();
    await socket?.close();
  }
}

const autonomousInstructions =
    '当本地授权通知明确表示自主模拟已开启时，可以使用 simulation_plan 主动安排当前批准时段内的波形与相对强度，不需逐步要求用户重复指令。没有授权不可安排。用户反馈优先，计划随时失效；工具返回 scheduled 只表示安排成功，不代表步骤已经执行。不要把声音大小、沉默或推测的身体状态作为增强理由。';
const autonomousTool = {
  'type': 'function',
  'function': {
    'name': 'simulation_plan',
    'description': '在用户已批准的本地自主模拟时段内安排最多6步、最多30秒的计划。每步至少间隔3秒。不能授权或延长权限。',
    'parameters': {
      'type': 'object',
      'properties': {
        'steps': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 6,
          'items': {
            'type': 'object',
            'properties': {
              'after_ms': {'type': 'integer', 'minimum': 0, 'maximum': 30000},
              'action': {
                'type': 'string',
                'enum': [
                  'gentle_wave',
                  'soft_pulse',
                  'increase',
                  'decrease',
                  'hold',
                  'stop',
                ],
              },
            },
            'required': ['after_ms', 'action'],
            'additionalProperties': false,
          },
        },
      },
      'required': ['steps'],
      'additionalProperties': false,
    },
  },
};
