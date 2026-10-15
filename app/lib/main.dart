import 'control_slider.dart';
import 'network_lifecycle.dart';
import 'localization.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'model_provider.dart';
import 'api_model_provider.dart';
import 'model_settings.dart';
import 'chat_context.dart';
import 'waveform_panel.dart';
import 'waveform_store.dart';
import 'connection_panel.dart';
import 'preferences_store.dart';
import 'channel_console.dart';
import 'experience_hub.dart';
import 'experience_panel.dart';
import 'autopilot.dart';
import 'observation.dart';
import 'physical_output.dart';
import 'device_gateway.dart';
import 'release_panel.dart';
import 'voice_page.dart';
import 'warm_theme.dart';
import 'warm_splash.dart';
import 'app_distribution.dart';

import 'package:path_provider/path_provider.dart';

const ink = Color(0xFF203E3A),
    teal = Color(0xFF177E70),
    paper = Color(0xFFF5F6F1),
    muted = Color(0xFF74877F),
    coral = Color(0xFFB74F48);
void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(NetworkLifecycle.start());
  runApp(
    HapticsApp(
      veniceTest:
          const bool.fromEnvironment('VENICE_TEST_ENTRY', defaultValue: true) ||
          (Platform.isWindows && arguments.contains('--venice')),
    ),
  );
}

class HapticsApp extends StatelessWidget {
  const HapticsApp({
    super.key,
    this.waveformDirectory,
    this.modelProviderFactory,
    this.veniceTest = false,
  });
  final Future<Directory> Function()? waveformDirectory;
  final ModelProvider Function()? modelProviderFactory;
  final bool veniceTest;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AI Haptics Lab',
    debugShowCheckedModeBanner: false,
    theme: veniceTest
        ? warmTheme()
        : ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: paper,
            colorScheme: ColorScheme.fromSeed(
              seedColor: teal,
              surface: Colors.white,
            ),
            fontFamily: 'Microsoft YaHei',
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                backgroundColor: teal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: paper,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
    home: veniceTest
        ? const WarmSplash(child: DistributionGate())
        : const String.fromEnvironment('BETA_SERVICE_URL').isNotEmpty
        ? const VoicePage()
        : LabPage(
            waveformDirectory: waveformDirectory,
            modelProviderFactory: modelProviderFactory,
          ),
  );
}

class LabPage extends StatefulWidget {
  const LabPage({super.key, this.waveformDirectory, this.modelProviderFactory});
  final Future<Directory> Function()? waveformDirectory;
  final ModelProvider Function()? modelProviderFactory;
  @override
  State<LabPage> createState() => _LabPageState();
}

class _LabPageState extends State<LabPage> with WidgetsBindingObserver {
  CoreBridge? core;
  Map<String, dynamic> state = {};
  String? startupError;
  Timer? timer;
  double limit = 0.3;
  int tab = 0;
  bool sending = false;
  bool testingModel = false;
  int chatGeneration = 0;
  ModelProvider? activeProvider;
  String lastAction = '尚无动作', modelTestStatus = '';
  String? selectedWaveform;
  PreferencesStore? preferencesStore;
  bool preferencesLoading = true, preferencesSaving = false;
  int preferencesRevision = 0;
  String preferencesStatus = '正在读取本机配置…';
  ChatMessage? pendingReply;
  WaveformStore? waveStore;
  bool libraryLoading = true;
  final connectionKey = GlobalKey();
  final input = TextEditingController();
  final modelConfiguration = ModelConfiguration();
  final List<ChatMessage> messages = [];
  late final ExperienceHub experience;
  late final Autopilot autopilot;
  final observation = Observation();
  final physical = PhysicalOutput();
  bool autoRequiresLease = false;
  bool autoWasRunning = false, spaceHandled = false;
  Timer? spaceHold;
  String get phase => state['phase'] as String? ?? 'disconnected';
  bool get authorized => phase == 'authorized' || phase == 'playing';
  bool get connected => state['connected'] == true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    experience = ExperienceHub((request) => act(request, notify: false));
    autopilot = Autopilot(
      allowed: () =>
          mounted && !preferencesLoading && (!autoRequiresLease || authorized),
      canRun: () => !sending && !preferencesSaving && !experience.busy,
      runRound: () async {
        if (!sending) {
          await sendMessage(
            experience.tr(
              '请根据最近的对话自然地继续一个简短回合，不要把自动消息当作增加强度的请求。',
              'Continue a short conversational turn from recent context. This automatic message does not request increased output.',
            ),
          );
        }
      },
      onChanged: () {
        final ended = autoWasRunning && !autopilot.active;
        autoWasRunning = autopilot.active;
        if (ended && mounted) {
          stop();
          return;
        }
        if (mounted) setState(() {});
      },
    );
    HardwareKeyboard.instance.addHandler(handleKey);
    physical.onFault = () {
      if (mounted && core != null) stop();
    };
    try {
      core = CoreBridge();
      refresh();
      unawaited(restoreWaveforms());
      timer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => refresh(),
      );
    } catch (e) {
      startupError = '控制核心未能加载。请使用项目构建脚本重新构建。\n$e';
    }
  }

  Future<void> restoreWaveforms() async {
    try {
      final directory =
          await (widget.waveformDirectory ?? getApplicationSupportDirectory)();
      if (!mounted) return;
      preferencesStore = PreferencesStore(directory);
      try {
        final saved = await preferencesStore!.load();
        if (!mounted) return;
        setState(() {
          if (saved != null) {
            modelConfiguration.restorePreferences(saved);
            preferencesRevision++;
          }
          preferencesStatus = saved == null
              ? '尚未保存配置。'
              : '已恢复配置与偏好；密钥需重新填写，控制仍需本地授权。';
        });
      } catch (_) {
        if (mounted) {
          setState(
            () => preferencesStatus = '已保存配置未通过校验，未加载；原文件已保留，可修改后保存或删除。',
          );
        }
      }
      if (!mounted) return;
      setState(() => preferencesLoading = false);
      final store = WaveformStore(
        Directory('${directory.path}/waveforms-v1'),
        core!,
      );
      final errors = await store.restore();
      if (!mounted) return;
      setState(() => waveStore = store);
      await experience.load(directory);
      refresh();
      if (errors.isNotEmpty) toast(errors.first);
    } catch (_) {
      if (mounted) setState(() => preferencesStatus = '本机存储不可用，配置仅保留在本次运行内。');
    } finally {
      if (mounted) {
        setState(() {
          libraryLoading = false;
          preferencesLoading = false;
          experience.loading = false;
        });
      }
    }
  }

  Future<void> savePreferences({bool forget = false}) async {
    if (preferencesStore == null ||
        preferencesSaving ||
        preferencesLoading ||
        sending) {
      return;
    }
    setState(() => preferencesSaving = true);
    try {
      if (forget) {
        await preferencesStore!.forget();
      } else {
        await preferencesStore!.save(modelConfiguration.savedPreferences());
      }
      if (mounted) {
        setState(
          () => preferencesStatus = forget
              ? '已删除本机保存的配置；当前输入仍可使用。'
              : '配置与偏好已保存；不含 API 密钥、聊天记录或授权。',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => preferencesStatus = error is FormatException
              ? '未保存：${error.message}'
              : '本机配置操作失败，请检查存储空间和权限。',
        );
      }
    } finally {
      if (mounted) setState(() => preferencesSaving = false);
    }
  }

  List<dynamic> get compatibleWaveforms => (state['waveforms'] as List? ?? [])
      .where(
        (w) =>
            ((w['format'] == 'dglab_v3') ==
                (state['device']?['id'] == 'sim_dglab')) &&
            (w['channels'] as num) <=
                (state['device']?['channels'] as num? ?? 0),
      )
      .toList();

  String? get effectiveWaveform {
    final waves = compatibleWaveforms;
    if (waves.any((w) => w['id'] == selectedWaveform)) return selectedWaveform;
    return state['device']?['id'] == 'sim_dglab' && waves.isNotEmpty
        ? waves.first['id'] as String
        : null;
  }

  void refresh() {
    if (!mounted || core == null) return;
    try {
      final result = core!.call({'op': 'snapshot'});
      if (result['state'] is Map<String, dynamic>) {
        final expired =
            authorized &&
            !['authorized', 'playing'].contains(result['state']['phase']);
        setState(() {
          if (state['device']?['id'] != result['state']['device']?['id']) {
            selectedWaveform = null;
          }
          state = result['state'];
        });
        physical.consume(state);
        if (expired && autopilot.active) autopilot.stop(reason: '授权已结束，自动回合暂停');
      } else {
        setState(() {
          startupError = '控制核心不可用，请关闭并重启应用。';
        });
      }
    } catch (_) {
      setState(() {
        startupError = '读取核心状态失败，请关闭并重启应用。';
      });
    }
  }

  Map<String, dynamic> act(Map<String, dynamic> request, {bool notify = true}) {
    if (experience.busy &&
        ['authorize', 'connect', 'reset_simulation'].contains(request['op'])) {
      if (notify) toast('内容正在保存，请稍候 / Content is being saved');
      return {'ok': false, 'error': 'content_busy'};
    }
    try {
      final result = core!.call(request);
      if (result['state'] is Map<String, dynamic>) {
        setState(() {
          if (state['device']?['id'] != result['state']['device']?['id']) {
            selectedWaveform = null;
          }
          state = result['state'];
        });
        physical.consume(state);
      }
      if (result['ok'] != true && notify) {
        toast(errorText(result['error'].toString()));
      }
      return result;
    } catch (_) {
      if (notify) toast('控制核心暂不可用');
      return {'ok': false};
    }
  }

  void toast(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: LText(text)));
    }
  }

  void stop() {
    spaceHold?.cancel();
    autopilot.stop();
    experience.pause();
    unawaited(observation.stopAll());
    unawaited(physical.stop());
    chatGeneration++;
    activeProvider?.cancel();
    activeProvider = null;
    sending = false;
    if (testingModel) modelTestStatus = '连接测试已取消，可重新测试。';
    testingModel = false;
    pendingReply?.text = '动作回执已保留，后续模型回复已取消。';
    pendingReply = null;
    act({'op': 'stop'});
    setState(() => lastAction = '已停止 · 授权及待处理动作已撤销');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState value) {
    if ([
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.detached,
        ].contains(value) &&
        core != null) {
      stop();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    spaceHold?.cancel();
    HardwareKeyboard.instance.removeHandler(handleKey);
    autopilot.dispose();
    experience.dispose();
    observation.dispose();
    physical.dispose();
    chatGeneration++;
    activeProvider?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (core != null) core!.call({'op': 'stop'});
    input.dispose();
    modelConfiguration.dispose();
    super.dispose();
  }

  Future<void> sendMessage([String? suggestion]) async {
    final text = (suggestion ?? input.text).trim();
    if (text.isEmpty) return;
    if (text.length > 2000) {
      toast('消息请控制在 2000 字以内');
      return;
    }
    if (text.contains('停止') ||
        ['停', '停下', '停一下', '不要了', '不舒服'].any(text.contains) ||
        text.toLowerCase() == 'stop') {
      stop();
      input.clear();
      setState(() {
        messages.add(ChatMessage(user: true, text: text));
        messages.add(
          ChatMessage(
            user: false,
            text: '已停止。旧请求已失效；继续体验需要重新授权。',
            receipt: lastAction,
          ),
        );
        if (messages.length > 40) messages.removeRange(0, messages.length - 40);
      });
      return;
    }
    if (sending || preferencesLoading || preferencesSaving) return;
    refresh();
    final stamp = ++chatGeneration;
    final canControl = authorized && state['ai_control'] == true;
    final begin = canControl ? act({'op': 'begin_ai'}) : null;
    if (canControl && begin?['ok'] != true) return;
    final ticket = begin?['result']['ticket'],
        alias = state['device']?['id'] as String? ?? 'none';
    final chatContext = ChatContext(
      controlAllowed: canControl,
      gain: (state['gain_target'] as num? ?? 0.5).toDouble(),
      style: modelConfiguration.style,
      persona: modelConfiguration.persona.text,
      character: experience.character.prompt(experience.language),
      nickname: experience.nickname,
      examples: experience.character.examples,
      language: experience.language,
      observation: observation.summary,
      imageData: observation.imageData,
      simulationOnly: !physical.armed,
      playing: phase == 'playing',
      remainingMs: (state['remaining_ms'] as num? ?? 0).toInt(),
      history: messages
          .map((m) => ChatTurn(m.user ? 'user' : 'assistant', m.text))
          .toList(),
      selectedWaveform: effectiveWaveform,
      channels: (state['channels'] as List? ?? [])
          .asMap()
          .entries
          .map(
            (c) => <String, dynamic>{
              ...Map<String, dynamic>.from(c.value),
              'note': experience.channelNotes[c.key],
            },
          )
          .toList(),
      patterns: (state['pattern_catalog'] as List? ?? [])
          .map((p) => p['id'] as String)
          .toList(),
      waveforms: compatibleWaveforms.map((w) => w['id'] as String).toList(),
    );
    setState(() {
      sending = true;
      messages.add(ChatMessage(user: true, text: text));
      if (messages.length > 40) messages.removeRange(0, messages.length - 40);
    });
    input.clear();
    try {
      final provider =
          (widget.modelProviderFactory ?? modelConfiguration.createProvider)();
      activeProvider = provider;
      final reply = await provider.respond(text, alias, context: chatContext);
      if (!mounted || stamp != chatGeneration) return;
      final noop = reply.intent['action'] == 'noop';
      if (noop && ticket != null) {
        act({'op': 'cancel_ai', 'ticket': ticket}, notify: false);
      }
      final executed = noop
          ? <String, dynamic>{'ok': true}
          : ticket == null
          ? {'ok': reply.intent['action'] == 'noop', 'error': 'not_authorized'}
          : act({
              'op': 'complete_ai',
              'ticket': ticket,
              'response': jsonEncode(reply.intent),
            }, notify: false);
      final receipt = describeAction(reply.intent, executed, chatContext.gain);
      setState(() => lastAction = receipt);
      var responseText = executed['ok'] == true
          ? (reply.text.isEmpty ? '动作已处理，请查看执行回执。' : reply.text)
          : '这次动作没有执行：${errorText(executed['error'].toString())}';
      final responseMessage = ChatMessage(
        user: false,
        text: provider is ApiModelProvider && reply.continuation != null
            ? '动作结果已记录，正在生成回复…'
            : responseText,
        receipt: receipt,
      );
      setState(() => messages.add(responseMessage));
      if (provider is ApiModelProvider && reply.continuation != null) {
        pendingReply = responseMessage;
        try {
          responseText = await provider.finishToolCall(reply, {
            'ok': executed['ok'] == true,
            'receipt': receipt,
            'phase': state['phase'],
            'gain_target': state['gain_target'],
            'remaining_ms': state['remaining_ms'],
            'simulation_only': !physical.armed,
            'physical_status': physical.status,
          });
        } catch (_) {
          responseText = '动作结果已记录在执行回执中；模型的补充回复暂未返回。';
        }
      }
      if (!mounted || stamp != chatGeneration) return;
      setState(() {
        responseMessage.text = responseText;
        pendingReply = null;
      });
    } catch (error) {
      if (mounted && stamp == chatGeneration) {
        if (ticket != null) {
          act({'op': 'cancel_ai', 'ticket': ticket}, notify: false);
        }
        setState(() {
          lastAction = '请求未完成 · 本次未执行新动作';
          messages.add(
            ChatMessage(
              user: false,
              text: error is ModelServiceException
                  ? error.message
                  : '模型未返回可执行结果。请检查模型地址、名称和接口模式。',
              receipt: lastAction,
            ),
          );
        });
      }
    } finally {
      if (mounted && stamp == chatGeneration) {
        setState(() {
          activeProvider = null;
          sending = false;
          if (messages.length > 40) {
            messages.removeRange(0, messages.length - 40);
          }
        });
      }
    }
  }

  String get controlStatus {
    if (!connected) return '未连接模拟器 · 仅聊天';
    if (!authorized) return '尚未授权或授权已到期 · 仅聊天';
    if (state['ai_control'] != true) return 'AI 动作已关闭 · 仅聊天';
    final seconds = ((state['remaining_ms'] as num? ?? 0) / 1000).ceil();
    return phase == 'playing'
        ? '${state['continuous'] == true ? '连续仿真中' : '短波形播放中'} · 剩余 $seconds 秒'
        : '已授权但未播放 · 剩余 $seconds 秒';
  }

  String describeAction(
    Map<String, dynamic> intent,
    Map<String, dynamic> result,
    double previousGain,
  ) {
    if (result['ok'] != true) {
      return '未执行 · ${errorText(result['error'].toString())}';
    }
    if (physical.armed && intent['action'] != 'noop') {
      return '动作已通过本地校验 · 实物短时任务已排程；执行状态请查看设备 / APP';
    }
    switch (intent['action']) {
      case 'channel_actions':
        return '通道动作已执行 · ${jsonEncode(result['result']?['executed'])}（仅仿真）';
      case 'set_gain':
        final gain = (state['gain_target'] as num).toDouble();
        final change =
            '相对强度 ${(previousGain * 100).round()}% → ${(gain * 100).round()}%';
        return '$change · ${phase == 'playing' ? ((state['limit'] as num) == 0 ? '授权上限为 0，输出仍为 0' : '已应用到当前仿真波形') : '当前未播放，点击「开始对话体验」后生效'}';
      case 'play_preset':
      case 'play_waveform':
        return '已执行 · ${state['continuous'] == true ? '连续体验已切换波形' : '已启动短波形'}（仅仿真）';
      case 'stop':
        return '已停止 · 需要重新授权';
      default:
        return '仅聊天 · $controlStatus';
    }
  }

  void startExperience() {
    if (libraryLoading ||
        !connected ||
        phase == 'playing' ||
        phase == 'unknown') {
      return;
    }
    final electrical = state['device']?['id'] == 'sim_dglab';
    final waveform = effectiveWaveform;
    if (!authorized) {
      if (act({'op': 'authorize', 'limit': limit, 'lease_ms': 30000})['ok'] !=
          true) {
        return;
      }
    }
    final result = act({
      'op': 'start_experience',
      if (waveform != null)
        'waveform_id': waveform
      else
        'preset_id': electrical ? 'lab_breathe' : 'gentle_wave',
    });
    setState(
      () => lastAction = result['ok'] == true
          ? '连续仿真已开始 · 现在可以说「强一点」「弱一点」；到授权期限自动停止'
          : '未开始 · ${errorText(result['error'].toString())}',
    );
  }

  Future<void> testModel() async {
    if (sending) return;
    final stamp = ++chatGeneration;
    setState(() {
      sending = true;
      testingModel = true;
      modelTestStatus = '正在测试，只发送测试问候…';
    });
    try {
      final provider =
          (widget.modelProviderFactory ?? modelConfiguration.createProvider)();
      activeProvider = provider;
      final reply = await provider.respond(
        '你好，请用一句中文确认连接正常。',
        'none',
        context: const ChatContext(controlAllowed: false),
      );
      if (mounted && stamp == chatGeneration) {
        setState(
          () => modelTestStatus = reply.intent['action'] == 'noop'
              ? '连接成功：${reply.text}'
              : '服务可达，但返回了未允许的动作；未执行任何动作。',
        );
      }
    } catch (error) {
      if (mounted && stamp == chatGeneration) {
        setState(
          () => modelTestStatus = error is ModelServiceException
              ? error.message
              : '连接失败，请检查模型地址、名称和模式。',
        );
      }
    } finally {
      if (mounted && stamp == chatGeneration) {
        setState(() {
          sending = false;
          testingModel = false;
          activeProvider = null;
        });
      }
    }
  }

  bool handleKey(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.space) return false;
    if (event is KeyUpEvent) {
      spaceHold?.cancel();
      spaceHold = null;
      final handled = spaceHandled;
      spaceHandled = false;
      return handled;
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    final typing =
        focus?.findAncestorStateOfType<EditableTextState>() != null ||
        focus?.widget is EditableText;
    if (event is KeyDownEvent && !typing) {
      spaceHandled = true;
      spaceHold?.cancel();
      spaceHold = Timer(const Duration(seconds: 1), () {
        if (mounted && core != null) stop();
      });
    }
    return spaceHandled;
  }

  Widget experiencePanel() => ExperiencePanel(
    hub: experience,
    auto: autopilot,
    stop: stop,
    roleChanged: () {
      stop();
      setState(() => messages.clear());
    },
    startAuto: (seconds, rounds) {
      autoRequiresLease = authorized;
      autopilot.start(
        every: Duration(seconds: seconds),
        rounds: rounds,
      );
    },
    feedback: (pattern) {
      act({
        'op': 'channel_actions',
        'actions': [
          {
            'channel': 0,
            'command': {
              'kind': 'pattern',
              'preset_id': pattern,
              'duration_ms': 3000,
              'repeat': false,
            },
          },
        ],
      });
    },
  );

  Future<void> selectPhysical(
    DglabV4Gateway gateway,
    RemoteDevice device,
  ) async {
    stop();
    await physical.bind(gateway, device);
    if (!mounted) return;
    act({'op': 'connect', 'device_id': 'sim_dglab'});
    setState(() {});
  }

  Future<void> armPhysical() async {
    if (libraryLoading || physical.unknown) return;
    stop();
    final stamp = chatGeneration;
    try {
      await physical.arm();
      if (!mounted || stamp != chatGeneration) {
        await physical.stop();
        return;
      }
      if (act({'op': 'authorize', 'limit': limit, 'lease_ms': 30000})['ok'] !=
          true) {
        await physical.stop();
      }
    } catch (e) {
      toast('$e');
    }
  }

  Widget physicalPanel() => ListenableBuilder(
    listenable: physical,
    builder: (context, _) => ExpansionTile(
      title: const LText('郊狼 3.0 实物输出 / Physical output'),
      subtitle: LText(
        physical.device?.name ?? '先在下方连接并选择设备 / Connect and select a device',
      ),
      children: [
        for (var channel = 0; channel < 2; channel++)
          Column(
            children: [
              LText(
                '${channel == 0 ? 'A' : 'B'} 硬上限 / Hard cap: ${physical.caps[channel]}',
              ),
              ControlSlider(
                value: physical.caps[channel].toDouble(),
                min: 0,
                max: 200,
                divisions: 200,
                onChanged: physical.armed || physical.stopping
                    ? null
                    : (v) {
                        physical.caps[channel] = v.round();
                        physical.changed();
                      },
              ),
            ],
          ),
        LText(physical.status),
        const LText(
          '启用后，A/B 控制台、波形与已授权 AI 动作会发给所选实物。\nOnce enabled, authorized console, waveform and AI actions reach the selected device.',
        ),
        FilledButton(
          onPressed:
              physical.device == null ||
                  physical.armed ||
                  physical.stopping ||
                  physical.unknown
              ? null
              : armPhysical,
          child: const LText('启用实物输出 30 秒 / Enable for 30s'),
        ),
        TextButton(
          onPressed: physical.device == null ? null : stop,
          child: const LText('停止 / 重试归零 · Stop / retry reset'),
        ),
      ],
    ),
  );

  Widget channelConsole() => ChannelConsole(
    key: ValueKey('channels-${experience.loading}'),
    state: state,
    act: act,
    notes: experience.channelNotes,
    onNoteSaved: (index, note) async {
      experience.channelNotes[index] = note;
      await experience.saveSettings();
    },
  );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 960;
    return LanguageScope(
      language: experience.language,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: paper,
          surfaceTintColor: paper,
          toolbarHeight: 84,
          titleSpacing: wide ? 32 : 20,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: teal,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.waves_rounded, color: Colors.white),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LText(
                        '触觉实验室',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          color: ink,
                        ),
                      ),
                      LText(
                        'AI HAPTICS  /  LAB',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 2,
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Language / 语言',
                icon: const Icon(Icons.language),
                onSelected: (lang) async {
                  stop();
                  setState(() => experience.language = lang);
                  try {
                    await experience.saveSettings();
                  } catch (_) {
                    toast('语言设置未保存 / Language preference not saved');
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'zh', child: Text('中文')),
                  PopupMenuItem(value: 'en', child: Text('English')),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE3EEE6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: LText(
                  physical.unknown
                      ? '停止状态未确认'
                      : physical.armed
                      ? '实物输出'
                      : '仅模拟',
                  style: const TextStyle(
                    fontSize: 12,
                    color: teal,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        body: startupError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SelectableText(startupError!),
                ),
              )
            : wide
            ? Padding(
                padding: const EdgeInsets.fromLTRB(32, 8, 32, 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 290,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            devicePanel(),
                            const SizedBox(height: 16),
                            policyPanel(),
                            const SizedBox(height: 16),
                            channelConsole(),
                            physicalPanel(),
                            const SizedBox(height: 16),
                            panel(
                              '外部设备连接',
                              '按协议读取实际设备能力',
                              ConnectionPanel(
                                key: connectionKey,
                                onDeviceSelected: selectPhysical,
                                beforeDisconnect: physical.stop,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: ListView(
                        children: [
                          sessionPanel(),
                          voiceEntry(),
                          const SizedBox(height: 20),
                          chatPanel(),
                          experiencePanel(),
                          ObservationPanel(
                            source: observation,
                            language: experience.language,
                          ),
                          const SizedBox(height: 20),
                          waveformPanel(),
                          PatternLibrary(state: state, act: act),
                          const SizedBox(height: 20),
                          diagnosticsPanel(),
                          ReleasePanel(hub: experience),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            : IndexedStack(
                index: tab,
                children: [
                  for (final children in <List<Widget>>[
                    [
                      sessionPanel(),
                      voiceEntry(),
                      const SizedBox(height: 16),
                      chatPanel(),
                      experiencePanel(),
                      ObservationPanel(
                        source: observation,
                        language: experience.language,
                      ),
                    ],
                    [
                      devicePanel(),
                      const SizedBox(height: 16),
                      policyPanel(),
                      channelConsole(),
                      physicalPanel(),
                      const SizedBox(height: 16),
                      panel(
                        '外部设备连接',
                        '按协议读取实际设备能力',
                        ConnectionPanel(
                          key: connectionKey,
                          onDeviceSelected: selectPhysical,
                          beforeDisconnect: physical.stop,
                        ),
                      ),
                    ],
                    [waveformPanel(), PatternLibrary(state: state, act: act)],
                    [diagnosticsPanel(), ReleasePanel(hub: experience)],
                  ])
                    SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: children,
                      ),
                    ),
                ],
              ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: wide ? 32 : 16,
                  vertical: 12,
                ),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: Color(0xFFE2E8DF))),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LText(
                            physical.unknown
                                ? '实物停止未确认 / Physical stop unconfirmed'
                                : phaseLabel(phase),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: ink,
                            ),
                          ),
                          LText(
                            phase == 'unknown'
                                ? '保留最后模拟输出，停止状态未确认'
                                : '控制权始终在你手中',
                            style: const TextStyle(fontSize: 11, color: muted),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      key: const Key('stop'),
                      onPressed: core == null ? null : stop,
                      style: FilledButton.styleFrom(backgroundColor: coral),
                      icon: const Icon(Icons.stop_rounded),
                      label: const LText('立即停止'),
                    ),
                  ],
                ),
              ),
              if (!wide)
                NavigationBar(
                  selectedIndex: tab,
                  onDestinationSelected: (value) => setState(() {
                    tab = value;
                  }),
                  destinations: [
                    NavigationDestination(
                      icon: const Icon(Icons.waves_rounded),
                      label: experience.tr('体验', 'Session'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.sensors_rounded),
                      label: experience.tr('设备', 'Devices'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.library_music_outlined),
                      label: experience.tr('波形', 'Waveforms'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.receipt_long_outlined),
                      label: experience.tr('记录', 'Activity'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget voiceEntry() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: OutlinedButton.icon(
      icon: const Icon(Icons.record_voice_over),
      label: Text(Platform.isWindows ? '实时语音 · 本机测试' : '实时语音内测 · 邀请码登录'),
      onPressed: () async {
        stop();
        await physical.stop();
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => VoicePage(
              roleContext: experience.character.prompt(experience.language),
            ),
          ),
        );
        if (mounted) refresh();
      },
    ),
  );

  Widget panel(
    String title,
    String subtitle,
    Widget child, {
    Widget? trailing,
  }) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE3E9E0)),
    ),
    child: Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: LText(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 5),
          LText(
            subtitle,
            style: const TextStyle(color: muted, fontSize: 12, height: 1.6),
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    ),
  );
  Widget devicePanel() => panel(
    '选择设备',
    '默认使用模拟；实物输出需单独启用',
    Column(
      children: [
        for (final dynamic device in state['devices'] ?? [])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              key: Key('device_${device['id']}'),
              onTap: connected || phase == 'unknown'
                  ? null
                  : () => act({'op': 'connect', 'device_id': device['id']}),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: state['device']?['id'] == device['id']
                      ? const Color(0xFFE6F2EB)
                      : paper,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      device['channels'] == 2
                          ? Icons.graphic_eq
                          : Icons.sensors,
                      color: teal,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LText(
                            device['name'],
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          LText(
                            state['device']?['id'] == device['id'] && connected
                                ? '已连接'
                                : '${device['channels']} 个模拟通道',
                            style: const TextStyle(fontSize: 11, color: muted),
                          ),
                        ],
                      ),
                    ),
                    if (state['device']?['id'] == device['id'] && connected)
                      const Icon(Icons.check_circle, color: teal, size: 18),
                  ],
                ),
              ),
            ),
          ),
        if (connected)
          TextButton(
            onPressed: () => act({'op': 'disconnect'}),
            child: const LText('断开连接'),
          ),
        if (phase == 'unknown')
          OutlinedButton(
            onPressed: () => act({'op': 'reset_simulation'}),
            child: const LText('复位虚拟设备'),
          ),
      ],
    ),
  );
  Widget policyPanel() => panel(
    '本次授权',
    '上限与期限由本地控制核心执行',
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: LText('模拟输出上限', style: TextStyle(fontSize: 13)),
            ),
            LText(
              '${(limit * 100).round()}%',
              style: const TextStyle(
                fontSize: 25,
                color: teal,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        ControlSlider(
          value: limit,
          divisions: 20,
          onChanged: authorized || phase == 'unknown'
              ? null
              : (v) => setState(() {
                  limit = v;
                }),
        ),
        const LText(
          '每次授权 30 秒 · 导入波形最长 20 秒',
          style: TextStyle(fontSize: 11, color: muted),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('authorize'),
            onPressed:
                !libraryLoading &&
                    connected &&
                    ['ready', 'stopped'].contains(phase)
                ? () => act({
                    'op': 'authorize',
                    'limit': limit,
                    'lease_ms': 30000,
                  })
                : null,
            child: LText(
              libraryLoading
                  ? '正在恢复波形库…'
                  : phase == 'stopped'
                  ? '重新授权体验'
                  : '授权并开始',
            ),
          ),
        ),
        const SizedBox(height: 12),
        const LText(
          '离开应用会撤销会话。数值仅用于仿真，不代表真实设备的安全强度。',
          style: TextStyle(fontSize: 11, height: 1.6, color: muted),
        ),
      ],
    ),
  );
  Widget sessionPanel() {
    final output = state['output'] as List? ?? [0, 0];
    return panel(
      '看见每一次变化',
      connected ? state['device']['name'] as String : '先到设备页连接一个模拟器，再开始体验',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              LText(
                '${((output[0] as num) * 100).round()}',
                style: const TextStyle(
                  fontSize: 48,
                  height: 1,
                  color: teal,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 5, bottom: 5),
                child: LText('%  通道 A', style: TextStyle(color: muted)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    LText(
                      '${((state['remaining_ms'] as num? ?? 0) / 1000).ceil()} 秒',
                      style: const TextStyle(
                        fontSize: 19,
                        color: ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const LText(
                      '剩余授权时间',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 145,
            width: double.infinity,
            child: CustomPaint(
              painter: WavePainter(
                state['samples'] as List? ?? [],
                (state['limit'] as num? ?? 0.3).toDouble(),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(
                child: LText('相对强度（在授权上限内）', style: TextStyle(fontSize: 12)),
              ),
              LText(
                '${((state['gain_target'] as num? ?? 0.5) * 100).round()}%',
              ),
            ],
          ),
          ControlSlider(
            key: const Key('gain_slider'),
            value: (state['gain_target'] as num? ?? 0.5).toDouble(),
            divisions: 20,
            onChanged: authorized
                ? (v) => act({'op': 'set_gain', 'gain': v})
                : null,
          ),
          const LText(
            '实际输出 = 波形幅度 × 相对强度 × 授权上限',
            style: TextStyle(fontSize: 11, color: muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in const {
                'gentle_wave': '柔和起伏',
                'soft_pulse': '短脉冲',
                'dual_alternate': '双通道交替',
              }.entries)
                OutlinedButton(
                  key: Key(entry.key),
                  onPressed:
                      phase == 'authorized' &&
                          state['device']?['id'] != 'sim_dglab' &&
                          (entry.key != 'dual_alternate' ||
                              state['device']?['channels'] == 2)
                      ? () => act({'op': 'play', 'preset_id': entry.key})
                      : null,
                  child: LText(entry.value),
                ),
            ],
          ),
          if (phase == 'unknown')
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LText(
                '模拟故障：停止未确认。曲线保留最后输出，重新连接与授权已锁定。',
                style: TextStyle(color: coral, fontSize: 12),
              ),
            ),
        ],
      ),
      trailing: const Icon(Icons.show_chart, color: teal),
    );
  }

  Widget chatPanel() => panel(
    '与助手一起体验',
    modelConfiguration.label,
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (messages.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: paper,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const LText(
              '可以直接聊天。连接模拟器后点击「开始对话体验」，再试试「强一点」或「弱一点」。自然对话请在下方配置模型 API。',
              style: TextStyle(color: muted, height: 1.8),
            ),
          ),
        if (messages.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 210),
            // Keep message semantics attached to stable children. Reversing a
            // lazy list on every reply churned the Windows accessibility tree.
            child: SingleChildScrollView(
              reverse: true,
              child: Column(
                children: messages
                    .map(
                      (m) => Align(
                        key: ObjectKey(m),
                        alignment: m.user
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: m.user ? const Color(0xFFE6F2EB) : paper,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                m.text,
                                style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.6,
                                ),
                              ),
                              if (m.receipt != null) ...[
                                const SizedBox(height: 6),
                                LText(
                                  '本条执行回执：${m.receipt}',
                                  key: const Key('message_receipt'),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: teal,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        const SizedBox(height: 14),
        LText(
          controlStatus,
          key: const Key('chat_control_status'),
          style: const TextStyle(fontSize: 12, color: teal),
        ),
        const SizedBox(height: 8),
        Container(
          key: const Key('action_receipt'),
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: paper,
            borderRadius: BorderRadius.circular(10),
          ),
          child: LText(
            '执行回执：$lastAction',
            style: const TextStyle(fontSize: 12, height: 1.5),
          ),
        ),
        const SizedBox(height: 8),
        if (connected) ...[
          InputDecorator(
            decoration: const InputDecoration(label: LText('体验波形')),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const Key('experience_waveform'),
                value: effectiveWaveform ?? '',
                isExpanded: true,
                isDense: true,
                items: [
                  if (state['device']?['id'] != 'sim_dglab' ||
                      compatibleWaveforms.isEmpty)
                    DropdownMenuItem(
                      value: '',
                      child: LText(
                        state['device']?['id'] == 'sim_dglab'
                            ? '内置 · 呼吸起伏'
                            : '内置 · 柔和起伏',
                      ),
                    ),
                  for (final wave in compatibleWaveforms)
                    DropdownMenuItem(
                      value: wave['id'] as String,
                      child: LText('导入 · ${wave['name']}'),
                    ),
                ],
                onChanged:
                    sending ||
                        libraryLoading ||
                        phase == 'playing' ||
                        phase == 'unknown'
                    ? null
                    : (value) => setState(() => selectedWaveform = value),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        OutlinedButton.icon(
          key: const Key('start_experience'),
          onPressed:
              !libraryLoading &&
                  connected &&
                  phase != 'playing' &&
                  phase != 'unknown' &&
                  !sending
              ? startExperience
              : null,
          icon: const Icon(Icons.play_circle_outline),
          label: const LText('开始对话体验'),
        ),
        LText(
          authorized
              ? '循环仿真波形，直到本次授权到期或立即停止。'
              : '点击即按上限 ${(limit * 100).round()}% 授权 30 秒并开始仿真。需先连接模拟器。',
          style: const TextStyle(fontSize: 11, color: muted),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('chat_input'),
                controller: input,
                maxLength: 2000,
                decoration: const InputDecoration(
                  hint: LText('输入想体验的节奏…'),
                  counterText: '',
                ),
                onSubmitted: (_) => sendMessage(),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filled(
              key: const Key('send'),
              onPressed: !sending && !preferencesLoading && !preferencesSaving
                  ? () => sendMessage()
                  : null,
              icon: Icon(sending ? Icons.hourglass_top : Icons.arrow_upward),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final text in ['陪我聊聊', '柔和起伏', '强一点', '弱一点', '播放导入波形'])
              ActionChip(
                label: LText(text, style: const TextStyle(fontSize: 11)),
                onPressed: !sending ? () => sendMessage(text) : null,
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const LText('允许 AI 提议波形和相对强度', style: TextStyle(fontSize: 12)),
          subtitle: const LText(
            '仍需本地授权。关闭会立即撤销待处理动作。',
            style: TextStyle(fontSize: 11),
          ),
          value: state['ai_control'] == true,
          onChanged: (v) => act({'op': 'set_ai_control', 'enabled': v}),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final style in ['温柔', '俏皮', '简洁'])
              ChoiceChip(
                label: LText(style),
                selected: modelConfiguration.style == style,
                onSelected: sending || preferencesLoading || preferencesSaving
                    ? null
                    : (_) => setState(() {
                        modelConfiguration.style = style;
                        preferencesStatus = '偏好已修改，点击保存后下次启动可恢复。';
                      }),
              ),
            TextButton(
              onPressed: sending
                  ? null
                  : () => setState(() => messages.clear()),
              child: const LText('清空聊天'),
            ),
          ],
        ),
        ModelSettings(
          key: ValueKey(preferencesRevision),
          configuration: modelConfiguration,
          busy: sending || preferencesLoading || preferencesSaving,
          onChanged: () => setState(() {
            modelTestStatus = '';
            preferencesStatus = '配置已修改，尚未保存；密钥始终只保留在内存。';
          }),
          onTest: testModel,
          testStatus: modelTestStatus,
          onSave: preferencesStore == null ? null : () => savePreferences(),
          onForget: preferencesStore == null
              ? null
              : () => savePreferences(forget: true),
          storageStatus: preferencesStatus,
        ),
      ],
    ),
  );
  Widget waveformPanel() => panel(
    '波形库',
    '先预览再导入；导入不启动输出',
    core == null
        ? const LText('核心未加载')
        : WaveformPanel(
            core: core!,
            state: state,
            refresh: refresh,
            store: waveStore,
            loading: libraryLoading || experience.busy,
          ),
  );
  Widget diagnosticsPanel() => panel(
    '运行记录',
    '仅记录控制事件；聊天内容不写入诊断记录',
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state['device']?['id'] == 'sim_fault')
          DropdownButtonFormField<String>(
            initialValue: state['fault'] as String? ?? 'none',
            decoration: const InputDecoration(label: LText('故障模拟')),
            items: const [
              DropdownMenuItem(value: 'none', child: LText('正常模拟')),
              DropdownMenuItem(
                value: 'hold_on_disconnect',
                child: LText('断线后保持最后输出'),
              ),
              DropdownMenuItem(
                value: 'stop_unconfirmed',
                child: LText('停止无法确认'),
              ),
            ],
            onChanged: phase == 'unknown'
                ? null
                : (v) {
                    if (v != null) act({'op': 'set_fault', 'fault': v});
                  },
          ),
        const SizedBox(height: 10),
        for (final dynamic event
            in (state['events'] as List? ?? []).reversed.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 58,
                  child: LText(
                    '${((event['at_ms'] as num) / 1000).toStringAsFixed(1)}s',
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                ),
                Expanded(
                  child: LText(
                    event['message'],
                    style: const TextStyle(fontSize: 12, color: ink),
                  ),
                ),
              ],
            ),
          ),
        if ((state['events'] as List? ?? []).isEmpty)
          const LText(
            '连接设备后，事件会显示在这里。',
            style: TextStyle(color: muted, fontSize: 12),
          ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: showDiagnostics,
          icon: const Icon(Icons.description_outlined, size: 16),
          label: const LText('预览诊断报告'),
        ),
      ],
    ),
  );
  Future<void> showDiagnostics() async {
    final report = const JsonEncoder.withIndent('  ').convert({
      'simulation_only': true,
      'core_version': state['core_version'],
      'phase': state['phase'],
      'output_evidence': state['output_evidence'],
      'events': state['events'],
    });
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('诊断报告预览'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: SelectableText(report, style: const TextStyle(fontSize: 12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('关闭'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (context.mounted) Navigator.pop(context);
            },
            child: const LText('复制报告'),
          ),
        ],
      ),
    );
  }
}

String phaseLabel(String phase) =>
    const {
      'disconnected': '等待连接',
      'ready': '设备就绪 · 尚未授权',
      'authorized': '已授权 · 等待动作',
      'playing': '模拟预设执行中',
      'stopped': '已停止 · 等待重新授权',
      'unknown': '停止状态未确认',
    }[phase] ??
    phase;
String errorText(String error) =>
    const {
      'not_authorized': '请先连接设备并授权',
      'stale_or_duplicate_ticket': '旧请求已失效，已保留你最新的操作',
      'stale_ticket': '请求已失效',
      'lease_too_short': '剩余授权时间不足，请停止后重新授权',
      'busy': '上一个预设还在执行',
      'capability_mismatch': '当前设备不支持这个预设',
      'invalid_intent': '模型动作格式不符合要求',
      'device_mismatch': '模型指定的设备与当前设备不一致',
      'cannot_authorize': '当前状态不能授权',
      'unknown_state_locked': '停止状态未知，需要复位虚拟设备',
      'ai_control_disabled': 'AI 动作已关闭，仍可聊天',
      'ai_gain_step_too_large': 'AI 每次最多上调 10 个百分点',
      'ai_gain_rate_limited': '上调过于频繁，请稍后再试',
      'waveform_capability_mismatch': '此波形与当前模拟器类型或通道数不匹配',
    }[error] ??
    error;

class WavePainter extends CustomPainter {
  WavePainter(this.samples, this.limit);
  final List samples;
  final double limit;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0xFFE8EDE5)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    canvas.drawLine(
      Offset(0, size.height * (1 - limit)),
      Offset(size.width, size.height * (1 - limit)),
      Paint()
        ..color = teal.withValues(alpha: 0.2)
        ..strokeWidth = 1.5,
    );
    if (samples.isEmpty) return;
    final end = (samples.last['at_ms'] as num).toDouble();
    for (var channel = 1; channel >= 0; channel--) {
      final path = Path();
      var first = true;
      for (final dynamic s in samples) {
        final x = (1 - (end - (s['at_ms'] as num)) / 8000) * size.width,
            y =
                size.height *
                (1 -
                    ((s['values'][channel] as num).toDouble().clamp(0.0, 1.0)));
        if (first) {
          path.moveTo(x, y);
          first = false;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = (channel == 0 ? teal : const Color(0xFFE3AC69))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WavePainter oldDelegate) => true;
}
