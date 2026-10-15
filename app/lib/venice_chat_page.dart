import 'venice_route.dart';
import 'warm_playback.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api_model_provider.dart';
import 'app_access.dart';
import 'chat_context.dart';
import 'model_provider.dart';
import 'venice_recorder.dart';
import 'venice_transcription.dart';
import 'venice_wave_session.dart';
import 'venice_control_reply.dart';
import 'venice_control_provider.dart';
import 'control_execution.dart';
import 'control_conversation.dart';
import 'control_reply_guard.dart';
import 'dialogue_guidance.dart';
import 'dialogue_guidance_context.dart';
import 'dialogue_guidance_runner.dart';
import 'physical_output.dart';
import 'warm_theme.dart';
import 'warm_library.dart';
import 'warm_wave_pages.dart';
import 'background_session.dart';
import 'warm_interaction.dart';
import 'warm_strength_limits.dart';
import 'network_diagnostics.dart';
import 'venice_tts.dart';
import 'speech_audio_player.dart';
import 'speech_output.dart';
import 'chat_stream.dart';
import 'speech_widgets.dart';
import 'continuous_voice.dart';

part 'warm_chat_view.dart';
part 'continuous_chat.dart';

/// Local operator-only evaluation. Never reads the Qwen credential or sends
/// provider credentials to a configurable origin. Opening the page is offline.
class VeniceLocalKey {
  static const embeddedKey = String.fromEnvironment('VENICE_LOCAL_TEST_KEY');
  static bool get isEmbedded => embeddedKey.isNotEmpty;

  static Future<String> load() async {
    if (VeniceRoute.isRelay) {
      if (VeniceRoute.relayToken.isEmpty) throw StateError("key_missing");
      return VeniceRoute.relayToken;
    }
    if (isEmbedded) {
      if (!RegExp(r'^VENICE_INFERENCE_KEY_[A-Za-z0-9_-]+$')
          .hasMatch(embeddedKey)) {
        throw StateError('key_invalid');
      }
      return embeddedKey;
    }
    if (!Platform.isWindows) throw StateError('mobile_key_not_configured');
    final decoded = await const MethodChannel('aihaptics/pcm')
        .invokeMethod<Uint8List>('load_venice_key');
    if (decoded == null) throw StateError('key_unavailable');
    // Channel buffers may be immutable; clear our writable copy only.
    final raw = Uint8List.fromList(decoded);
    try {
      final key = utf8.decode(raw).trim();
      if (!RegExp(r'^VENICE_INFERENCE_KEY_[A-Za-z0-9_-]+$').hasMatch(key)) {
        throw StateError('key_invalid');
      }
      return key;
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
  }
}

class VeniceChatPage extends StatefulWidget {
  const VeniceChatPage({
    super.key,
    this.role = AppRole.user,
    this.onLogout,
    this.selfHosted = false,
    this.loadKey = VeniceLocalKey.load,
    this.recorder,
    this.transcriberFactory,
    this.chatFactory,
    this.streamingChatFactory,
    this.plannerFactory,
    this.guidanceFactory,
    this.enableDialogueGuidance = true,
    this.guidanceRunner,
    this.waveSession,
    this.preferencesDirectory,
    this.ttsFactory,
    this.speechPlayer,
    this.continuousCapture,
  });
  final AppRole role;
  final VoidCallback? onLogout;
  final bool selfHosted;
  final Future<String> Function() loadKey;
  final VeniceRecorder? recorder;
  final VeniceTranscriber Function(String)? transcriberFactory;
  final ModelProvider Function(String, String)? chatFactory;
  final ModelProvider Function(String, String, void Function(String))?
  streamingChatFactory;
  final ModelProvider Function(String, String)? plannerFactory;
  final ModelProvider Function(String, String)? guidanceFactory;

  /// Explicit opt-out for isolated fixtures or callers supplying their own flow.
  final bool enableDialogueGuidance;
  final DialogueGuidanceRunner? guidanceRunner;
  final VeniceWaveSession? waveSession;
  final Directory? preferencesDirectory;
  final VeniceTtsClient Function(String)? ttsFactory;
  final SpeechAudioPlayer? speechPlayer;
  final SpeechCapture? continuousCapture;
  @override
  State<VeniceChatPage> createState() => _VeniceChatPageState();
}

class _VeniceChatPageState extends State<VeniceChatPage>
    with WidgetsBindingObserver {
  bool get developerAccess => widget.role == AppRole.administrator;
  bool loggingOut = false;
  final model = TextEditingController(text: veniceTextModel);
  final input = TextEditingController();
  final turns = <ChatTurn>[];
  final controlConversation = ControlConversation();
  ControlExecution? pendingExecution;
  String? secret;
  String status = '准备就绪后，可录音或输入文字。';
  String keyStatus = '正在读取本机加密密钥…';
  bool keyLoading = false;
  bool funded = false, busy = false;
  int generation = 0;
  ModelProvider? active;
  ModelProvider? planner;
  late final DialogueGuidanceRunner dialogueGuidance;
  String pendingReplyGuidance = '';
  late final VeniceWaveSession waves;
  final physical = PhysicalOutput();
  Timer? waveTimer;
  DateTime? lastWaveTick;
  VeniceTranscriber? transcriber;
  late final VeniceRecorder recorder;
  bool autoSend = true;
  String transcript = '';
  int? transcriptionMs;
  bool get occupied => busy || recorder.busy || keyLoading || loggingOut;
  late final WarmLibrary library;
  final background = BackgroundSession();
  final disconnectDeviceSignal = ValueNotifier<int>(0);
  bool deviceLinkActive = false;
  final chatScroll = ScrollController();
  final pageController = PageController(initialPage: 1);
  final controlReceipts = <ChatTurn, String>{};
  late final SpeechOutput speech;
  late final ContinuousVoice continuous;
  bool _continuousReady = false;
  bool _appForeground = true;
  Future<void>? _replySpeech;
  String _interruptedSpeech = '';
  final streamingText = ValueNotifier<String>('');
  Object? streamingMessageId;
  bool _speechWasActive = false;
  bool get speechSupported => Platform.isAndroid || widget.speechPlayer != null;

  void speechChanged() {
    if (continuous.running && speech.phase == SpeechOutputPhase.playing) {
      continuous.speaking();
    }
    if (speech.active != _speechWasActive) {
      _speechWasActive = speech.active;
      syncBackground();
    }
  }

  Future<void> speakTurn(ChatTurn turn) async {
    if (!speechSupported || !funded || secret == null || recorder.busy) return;
    if (continuous.enabled) await continuous.pause();
    await speech.play(
      turn,
      turn.text,
      voice: library.speechVoice,
      speed: library.speechSpeed,
    );
  }

  void setAutoSpeak(bool enabled) {
    library.autoSpeak = enabled;
    if (!enabled) unawaited(speech.stop());
    unawaited(library.save());
  }

  String? pendingControlReceipt;
  String _recordingUiStamp = "";
  void selectPage(int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => page = index);
    pageController.jumpToPage(index);
  }

  int page = 1;
  bool showRecording = false, quickControl = false;
  String? pendingText;
  bool _backgroundFailure = false;
  void updateView(VoidCallback update) => setState(update);

  void openDiagnostics() {
    if (!developerAccess || loggingOut) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Theme(
          data: warmTheme(),
          child: ConnectionDiagnostics(apiKey: secret, developerAccess: true),
        ),
      ),
    );
  }

  Future<bool> prepareBackground() async {
    final ok = await background.update(
      active: true,
      microphone: recorder.capturing || continuous.running && _continuousReady,
      continuous: continuous.running && _continuousReady,
      device: deviceLinkActive || waves.physical && waves.active,
      simulation: waves.active && !waves.physical,
      mediaPlayback: speech.active,
    );
    if (!ok && mounted) setState(() => status = '后台运行服务未能启动，请保持 App 前台并重试。');
    return ok;
  }

  Future<bool> connectionActivity(bool active) async {
    if (!mounted) return false;
    deviceLinkActive = active;
    final ok = await background.update(
      active:
          active ||
          busy ||
          recorder.capturing ||
          waves.active ||
          speech.active ||
          continuous.running,
      microphone: recorder.capturing || continuous.running && _continuousReady,
      continuous: continuous.running && _continuousReady,
      device: active || waves.physical && waves.active,
      simulation: waves.active && !waves.physical,
      mediaPlayback: speech.active,
    );
    if (!ok && active) deviceLinkActive = false;
    return ok;
  }

  void syncBackground() {
    if (!mounted || _backgroundFailure) return;
    unawaited(
      background
          .update(
            active:
                deviceLinkActive ||
                busy ||
                recorder.capturing ||
                waves.active ||
                speech.active ||
                continuous.running,
            microphone:
                recorder.capturing || continuous.running && _continuousReady,
            continuous: continuous.running && _continuousReady,
            device: deviceLinkActive || waves.active && waves.physical,
            simulation: waves.active && !waves.physical,
            mediaPlayback: speech.active,
          )
          .then((ok) {
            if (!ok && mounted) {
              _backgroundFailure = true;
              deviceLinkActive = false;
              disconnectDeviceSignal.value++;
              cancel();
              setState(() => status = '后台运行服务不可用，本轮已停止，请重新开始。');
              // Queue a final stop after any already pending media-service start.
              // Do not attach the failure handler again: stop must not recurse.
              unawaited(background.update(active: false));
              _backgroundFailure = false;
            }
          }),
    );
  }

  Future<void> startRecording() async {
    if (continuous.enabled) await continuous.end();
    await speech.stop();
    if (!mounted || occupied) return;
    setState(() => showRecording = true);
    await recorder.start();
    if (mounted && recorder.capturing) {
      if (!await background.update(
        active: true,
        microphone: true,
        device: deviceLinkActive || waves.active && waves.physical,
      )) {
        await recorder.stop();
        if (mounted) setState(() => status = '后台录音服务未启动，录音已暂停。请返回前台重新开始。');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    dialogueGuidance = widget.guidanceRunner ?? DialogueGuidanceRunner();
    waves =
        widget.waveSession ??
        VeniceWaveSession(allowSimulation: developerAccess);
    library = WarmLibrary(waves, directory: widget.preferencesDirectory);
    library.addListener(preferencesChanged);
    background.onStop = () {
      if (mounted) {
        deviceLinkActive = false;
        disconnectDeviceSignal.value++;
        cancel();
      }
    };
    waves.addListener(syncBackground);
    physical.onFault = () => waves.stop('设备连接异常，已撤销 AI 控制');
    waveTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now();
      if (lastWaveTick != null &&
          now.difference(lastWaveTick!).inMilliseconds > 600 &&
          waves.active &&
          waves.physical) {
        waves.stop('输出时钟中断，已停止');
      }
      lastWaveTick = now;
      waves.tick();
      if (waves.physical) physical.consume(waves.physicalState());
    });
    WidgetsBinding.instance.addObserver(this);
    recorder = widget.recorder ?? VeniceRecorder();
    speech = SpeechOutput(
      player: widget.speechPlayer ?? NativeSpeechAudioPlayer(),
      createClient: () =>
          widget.ttsFactory?.call(secret!) ?? VeniceTtsClient(apiKey: secret!),
      preparePlayback: () => background.update(
        active: true,
        mediaPlayback: true,
        microphone: continuous.running && _continuousReady,
        continuous: continuous.running && _continuousReady,
        device: deviceLinkActive || waves.physical && waves.active,
        simulation: waves.active && !waves.physical,
      ),
    );
    continuous = ContinuousVoice(
      capture: widget.continuousCapture ?? NativeSpeechCapture(),
      prepare: prepareContinuous,
      transcribe: transcribeContinuous,
      reply: replyContinuous,
      cancelWork: cancelContinuousWork,
      interruptReply: interruptContinuousReply,
    );
    continuous.addListener(continuousChanged);
    speech.onInterrupted = () {
      if (continuous.running) {
        unawaited(continuous.pause('播放被系统或耳机切换中断，点击继续后重新监听。'));
      }
    };
    background.onPauseVoice = () {
      if (continuous.enabled) unawaited(continuous.pause());
    };
    background.onEndVoice = () {
      if (continuous.enabled) unawaited(continuous.end());
    };
    speech.addListener(speechChanged);
    recorder.addListener(recordingChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(library.restore());
    });
    load();
  }

  void recordingChanged() {
    final stamp =
        '${recorder.phase}:${(recorder.seconds * 5).floor()}:${recorder.error}';
    if (mounted && stamp != _recordingUiStamp) {
      _recordingUiStamp = stamp;
      setState(() {});
      syncBackground();
    }
  }

  void preferencesChanged() {
    if (!mounted) return;
    setState(() {
      funded = library.funded;
      autoSend = library.autoSend;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused &&
        continuous.running &&
        !continuous.allowBackground) {
      unawaited(continuous.pause('已切到后台，麦克风已关闭；返回后点击继续。'));
    }
    if (state == AppLifecycleState.detached) {
      cancel();
    }
  }

  Future<void> transcribeRecording() async {
    if (busy || keyLoading || !funded || secret == null) return;
    unawaited(speech.stop());
    final current = ++generation;
    final shouldSend = autoSend;
    var succeeded = false;
    setState(() {
      busy = true;
      status = '正在停止录音…';
    });
    try {
      if (!await prepareBackground() || !mounted || current != generation) {
        return;
      }
      await recorder.stop();
      syncBackground();
      if (!mounted || current != generation) return;
      if (recorder.phase != RecordingPhase.ready) {
        setState(
          () => status = recorder.error.isEmpty ? '请先录音。' : recorder.error,
        );
        return;
      }
      final wav = recorder.wav();
      transcriber =
          widget.transcriberFactory?.call(secret!) ??
          VeniceTranscriber(apiKey: secret!);
      setState(() => status = '正在上传并转写 · $veniceSpeechModel');
      final timer = Stopwatch()..start();
      final text = await transcriber!.transcribe(wav);
      if (!mounted || current != generation) return;
      if (VeniceWaveSession.needsStop(text)) {
        waves.stop('识别到停止或不适反馈，已归零');
        unawaited(physical.stop());
      }
      setState(() {
        transcript = text;
        input.text = text;
        transcriptionMs = timer.elapsedMilliseconds;
        status = '转写完成 · ${(transcriptionMs! / 1000).toStringAsFixed(1)} 秒';
      });
      await recorder.discard();
      succeeded = true;
      if (mounted && current == generation) {
        setState(() => showRecording = false);
      }
    } on ModelServiceException catch (error) {
      if (mounted && current == generation) {
        setState(() => status = error.message);
      }
    } catch (_) {
      if (mounted && current == generation) {
        setState(() => status = '转写失败，录音保留在内存中，可手动重试或丢弃。');
      }
    } finally {
      if (mounted && current == generation) {
        setState(() {
          busy = false;
          transcriber = null;
        });
        syncBackground();
      }
    }
    if (succeeded && shouldSend && mounted && current == generation) {
      await send();
    }
  }

  Future<void> load() async {
    if (keyLoading) return;
    setState(() {
      keyLoading = true;
      keyStatus = widget.selfHosted ? '正在读取本次服务配置…' : '正在读取本机加密密钥…';
    });
    try {
      final key = await widget.loadKey().timeout(const Duration(seconds: 10));
      if (key.trim().isEmpty) throw StateError('key_missing');
      if (!mounted) return;
      setState(() {
        secret = key;
        keyStatus = VeniceRoute.isCloudRelay
            ? '云中继已配置；请用连接诊断检查云服务'
            : VeniceRoute.isRelay
            ? '本机中继已配置；请用连接诊断检查电脑服务'
            : VeniceLocalKey.isEmbedded
            ? '内置测试密钥已就绪；尚未连接 Venice，也未验证余额'
            : '本机密钥已加载；尚未连接 Venice，也未验证余额';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          secret = null;
          keyStatus = switch (error) {
            TimeoutException() => '读取本机密钥超时，请点击“重新读取密钥”。',
            MissingPluginException() => '密钥读取组件未加载，请从完整新版目录启动。',
            PlatformException(code: 'key_missing') =>
              'Windows 本机密钥库中没有密钥文件（key_missing）。请重新导入。',
            PlatformException(code: 'key_directory') =>
              '无法定位 Windows 本机密钥库（key_directory）。',
            PlatformException(code: 'key_read_denied') =>
              'Windows 拒绝读取本机密钥文件（key_read_denied）。',
            PlatformException(code: 'key_read_failed') =>
              '本机密钥文件读取中断（key_read_failed）。请重试。',
            PlatformException(code: 'key_file_invalid') =>
              '本机密钥文件为空或损坏（key_file_invalid）。请重新导入。',
            PlatformException(code: 'key_decrypt_failed') =>
              '本机密钥解密失败（key_decrypt_failed）。请使用导入时的 Windows 账户。',
            PlatformException() => '本机密钥组件返回异常（key_native_error）。请使用完整新版程序。',
            StateError(message: 'key_invalid') => '本机密钥格式不正确，请重新导入。',
            StateError(message: 'key_missing') =>
              widget.selfHosted
                  ? '离线浏览中；请返回服务配置后启用在线对话。'
                  : '本机密钥未配置（key_missing），请重新导入。',
            StateError(message: 'mobile_key_not_configured') =>
              '此手机包未配置测试服务，请安装已配置的个人测试版。',
            FormatException() => '本机密钥编码无效（key_encoding），请重新导入。',
            _ => '本机密钥读取出现异常（key_load_error），请重新读取。',
          };
        });
      }
    } finally {
      if (mounted) setState(() => keyLoading = false);
    }
  }

  Future<bool> send({bool retry = false, bool continuousTurn = false}) async {
    if (continuous.enabled && !continuousTurn) return false;
    var sent = false;
    _replySpeech = null;
    final text = retry ? (pendingText ?? input.text.trim()) : input.text.trim();
    final stateAtInput = waves.snapshot();
    if (VeniceWaveSession.needsStop(text)) {
      waves.stop('收到停止或不适反馈，已归零');
      unawaited(physical.stop());
    }
    if (occupied || !funded || secret == null || text.isEmpty) return false;
    unawaited(speech.stop());
    if (text.length > 2000) {
      setState(() => status = '每条消息最多 2000 字，请缩短后重试。');
      return false;
    }
    final current = ++generation;
    final controlTrace = NetworkTrace('控制轮次');
    controlTrace.mark(
      '开始 generation=$current retry=$retry voice=$continuousTurn · 字数 ${text.runes.length} · 短应答 ${isVocalizationOnly(text)} · 停止词 ${VeniceWaveSession.needsStop(text)} · ${waves.diagnosticState}',
    );
    final timer = Stopwatch()..start();
    streamingText.value = '';
    final voiceMessage = Object();
    streamingMessageId = voiceMessage;
    final splitter = SpeechSentences();
    final replyGuard = ControlReplyGuard(
      fallback: () => pendingExecution!.summary(waves.snapshot(), retry: retry),
      onReplacement: () => NetworkTrace(
        '聊天核对',
      ).mark('完成式已替换为真实回执 · status=${pendingExecution?.status} · retry=$retry'),
    );
    StreamController<String>? liveSentences;
    var liveStarted = false;
    var deferStreamingSpeech = false;
    Future<DialogueGuidance?>? guidanceWork;
    void streamText(String value, {bool complete = false}) {
      if (!mounted || current != generation) return;
      final checked = replyGuard.add(value, complete: complete);
      streamingText.value = checked;
      final sentences = splitter.add(checked, complete: complete);
      if (sentences.isEmpty) return;
      scrollToLatest();
      if ((!library.autoSpeak && !continuousTurn) ||
          !speechSupported ||
          recorder.busy ||
          deferStreamingSpeech) {
        return;
      }
      if (!liveStarted) {
        liveStarted = true;
        liveSentences = StreamController<String>();
        unawaited(
          _replySpeech = speech.play(
            voiceMessage,
            '',
            voice: library.speechVoice,
            speed: library.speechSpeed,
            sentences: liveSentences!.stream,
          ),
        );
      }
      for (final sentence in sentences) {
        liveSentences!.add(sentence);
      }
    }

    setState(() {
      busy = true;
      pendingText = text;
      if (!retry) {
        pendingControlReceipt = null;
        pendingExecution = null;
        pendingReplyGuidance = '';
      }
      status = '正在连接文字服务…';
    });
    scrollToLatest();
    try {
      if (!await prepareBackground() || !mounted || current != generation) {
        return false;
      }
      // This independent request can overlap control planning. It never receives
      // a device executor, and its result is used only by the subsequent chat.
      // Retries reuse the same advice and receipt; they do not repeat planning.
      if (!retry &&
          widget.enableDialogueGuidance &&
          !VeniceWaveSession.needsStop(text)) {
        final guidanceInput = buildDialogueGuidanceInput(text, turns);
        guidanceWork = dialogueGuidance.run(
          guidanceInput,
          createProvider: () =>
              widget.guidanceFactory?.call(secret!, veniceControlModel) ??
              createDialogueGuidanceProvider(
                endpoint: VeniceRoute.base,
                apiKey: secret!,
              ),
        );
      }
      void localReceipt(String status, String reason, String receipt) {
        pendingControlReceipt = receipt;
        pendingExecution = ControlExecution(
          status: status,
          reason: reason,
          action: status == 'stopped' || status == 'stop_requested'
              ? 'stop'
              : 'hold',
          before: stateAtInput,
          after: waves.snapshot(),
          text: receipt,
        );
      }

      final confirmedProposal =
          !retry && ControlConversation.isConfirmation(text)
          ? controlConversation.proposal(waves.snapshot())
          : null;
      if (!retry && VeniceWaveSession.needsStop(text)) {
        localReceipt(
          waves.physical ? 'stop_requested' : 'stopped',
          'explicit_stop',
          waves.receipt,
        );
        controlConversation.clearProposal();
      }
      if (pendingControlReceipt == null && isVocalizationOnly(text)) {
        localReceipt('held', 'vocalization', '本轮仅为短应答或无词发声，未调用控制接口，强度保持不变');
        controlConversation.clearProposal();
        NetworkTrace('控制结果').mark('短应答保护 · 跳过控制接口 · 不授予调整权限');
      }
      if (pendingControlReceipt == null &&
          ControlConversation.isConfirmation(text) &&
          confirmedProposal == null) {
        localReceipt(
          'held',
          'no_valid_proposal',
          '本轮保持当前波形和强度：没有待确认的明确操作，请说明通道和目标',
        );
      }
      if (pendingControlReceipt == null && waves.active) {
        setState(() => status = '正在处理波形控制…');
        final ticket = waves.epoch;
        controlTrace.mark(
          '发送规划 model=$veniceControlModel max_tokens=$veniceControlMaxTokens '
          'reasoning=default ticket=$ticket · ${waves.diagnosticState}',
        );
        final controlProvider =
            widget.plannerFactory?.call(secret!, veniceControlModel) ??
            createVeniceControlProvider(
              endpoint: VeniceRoute.base,
              apiKey: secret!,
              state: waves.snapshot(),
            );
        planner = controlProvider;
        try {
          final contextData = controlConversation.data(waves.snapshot(), turns);
          controlTrace.mark(
            '共享上下文 · 历史=${(contextData['recent_turns'] as List).length} '
            '· 上次动作=${controlConversation.lastApplied?.action ?? "none"} '
            '· 待确认=${contextData['pending_confirmation'] != null}',
          );
          final plannerInput = controlConversation.plannerInput(
            text,
            waves.snapshot(),
            turns,
          );
          controlConversation
              .clearProposal(); // One attempt, never an automatic repeat.
          final planned = await controlProvider.respond(plannerInput, '');
          if (!mounted || current != generation) {
            controlTrace.mark(
              '丢弃迟到规划 generation=$current current=$generation mounted=$mounted',
            );
            return false;
          }
          var command = decodeControlReply(planned.text);
          if (confirmedProposal != null &&
              command['action'] == 'set' &&
              ![
                'action',
                'a',
                'b',
                'waveform_id',
              ].every((key) => command[key] == confirmedProposal[key])) {
            command = {'action': 'hold'};
            controlTrace.mark('确认保护 · 规划偏离待确认目标，保持当前状态');
          }
          final action =
              const {'set', 'hold', 'stop'}.contains(command['action'])
              ? command['action']
              : 'invalid';
          controlTrace.mark(
            '规划返回 action=$action targetA=${command['a'] is int ? command['a'] : "none"} targetB=${command['b'] is int ? command['b'] : "none"} waveSame=${command['waveform_id'] == waves.selected} ticket=$ticket · ${waves.diagnosticState}',
          );
          pendingControlReceipt = waves.apply(command, ticket);
          pendingExecution = waves.lastExecution;
          controlTrace.mark(
            '执行返回 · 拒绝=${pendingControlReceipt!.startsWith("未执行")} 保持=${pendingControlReceipt!.contains("保持")} · ${waves.diagnosticState}',
          );
          NetworkTrace('控制结果').mark(
            '动作 ${command['action']} · ${pendingControlReceipt!.startsWith("未执行") ? "本地拒绝" : "本地处理完成"} · A=${waves.strength[0]} / B=${waves.strength[1]} · 上限 ${waves.cap}',
          );
        } catch (error) {
          if (!mounted || current != generation) return false;
          final failure = ControlReplyFailure.from(error);
          NetworkTrace('控制结果').mark('失败：${failure.code}');
          final stopPhysical =
              waves.physical && waves.active && waves.epoch == ticket;
          pendingControlReceipt = waves.controlFailed(failure.label, ticket);
          pendingExecution = ControlExecution(
            status: 'failed',
            reason: failure.code,
            action: 'invalid',
            before: stateAtInput,
            after: waves.snapshot(),
            text: pendingControlReceipt!,
          );
          if (stopPhysical) unawaited(physical.stop());
        } finally {
          if (identical(planner, controlProvider)) planner = null;
        }
      }
      if (pendingControlReceipt == null) {
        localReceipt('not_authorized', 'inactive', '本轮未执行控制：未开始互动或会话已停止');
      }
      pendingExecution ??= ControlExecution(
        status: 'held',
        reason: 'retry_without_evidence',
        action: 'hold',
        before: waves.snapshot(),
        after: waves.snapshot(),
        text: pendingControlReceipt!,
      );
      if (!retry) controlConversation.record(pendingExecution!);
      if (guidanceWork != null) {
        final advice = await guidanceWork;
        if (!mounted || current != generation) return false;
        pendingReplyGuidance = advice == null
            ? ''
            : jsonEncode(advice.toJson());
      }
      // A timed-out/cancelled request may still occupy one relay slot. During
      // its bounded cooldown, avoid overlapping chat with speech synthesis.
      deferStreamingSpeech = dialogueGuidance.networkMayStillBeBusy;
      NetworkTrace('对话导答').mark(
        '传给聊天 · 有效导答=${pendingReplyGuidance.isNotEmpty} '
        '· 重试复用=$retry · 延后语音=$deferStreamingSpeech '
        '· generation=$current · 回执=${pendingExecution!.status}',
      );
      controlTrace.mark(
        '结构化回执 status=${pendingExecution!.status} reason=${pendingExecution!.reason} '
        '· A=${pendingExecution!.before['a']}→${pendingExecution!.after['a']} '
        'B=${pendingExecution!.before['b']}→${pendingExecution!.after['b']} '
        '· 波形改变=${pendingExecution!.before['selected'] != pendingExecution!.after['selected']} '
        '· 设备确认=false · 聊天重试=$retry',
      );
      final executionReceipt = retry
          ? '重试仅补发聊天，不重复控制。此前结果：$pendingControlReceipt；当前 A=${waves.strength[0]} / B=${waves.strength[1]} · ${waves.active ? "运行中" : "已停止"}'
          : pendingControlReceipt!;
      controlTrace.mark(
        '传给聊天 · 回执拒绝=${executionReceipt.contains("未执行") || executionReceipt.contains("失败")} 保持=${executionReceipt.contains("保持")} · ${waves.diagnosticState}',
      );
      final provider =
          widget.streamingChatFactory?.call(
            secret!,
            model.text.trim(),
            streamText,
          ) ??
          widget.chatFactory?.call(secret!, model.text.trim()) ??
          ApiModelProvider(
            endpoint: VeniceRoute.base,
            model: model.text.trim(),
            apiKey: secret!,
            mode: ApiReplyMode.chat,
            maxTokens: 600,
            onText: streamText,
          );
      active = provider;
      setState(() => status = '正在等待 AI 回复…');
      final reply = await provider.respond(
        text,
        '',
        context: ChatContext(
          aiName: library.aiName,
          replyGuidance: pendingReplyGuidance,
          executionReceipt: jsonEncode({
            'description': executionReceipt,
            'execution': pendingExecution!.toJson(),
            'chat_retry_only': retry,
            'current_state': waves.snapshot(),
            // History already uses user/assistant roles below; do not repeat
            // user prose inside the authoritative receipt system message.
            'conversation': controlConversation.data(
              waves.snapshot(),
              const [],
            ),
          }),
          history: List.of(turns),
          examples: const [
            ChatTurn('user', '宝宝我好喜欢这种感觉'),
            ChatTurn('assistant', '喜欢就好呀宝宝，那我们再调高一点好不好呀。'),
            ChatTurn('user', '宝宝太大了，有点疼'),
            ChatTurn('assistant', '宝宝真是杂鱼呢，那我先调低一点好啦。'),
          ],
        ),
      );
      if (!mounted || current != generation) return false;
      streamText(reply.text, complete: true);
      controlTrace.mark(
        '聊天核对完成 · status=${pendingExecution!.status} '
        '· 状态仍一致=${pendingExecution!.matches(waves.snapshot())} '
        '· 原文长度=${reply.text.length} · 输出长度=${replyGuard.text.length}',
      );
      if (!retry) {
        controlConversation.rememberProposal(
          replyGuard.text,
          pendingExecution!,
          waves.snapshot(),
        );
      }
      if (liveSentences != null) unawaited(liveSentences!.close());
      final assistantTurn = ChatTurn('assistant', replyGuard.text);
      if (liveStarted && identical(speech.message, voiceMessage)) {
        speech.message = assistantTurn;
      }
      streamingText.value = '';
      setState(() {
        turns.addAll([ChatTurn('user', text), assistantTurn]);
        controlReceipts[assistantTurn] = executionReceipt;
        if (turns.length > 24) turns.removeRange(0, turns.length - 24);
        controlReceipts.removeWhere((turn, _) => !turns.contains(turn));
        input.clear();
        pendingText = null;
        status =
            '收到回复 · ${(timer.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒（完整文本耗时）';
      });
      scrollToLatest();
      if (!liveStarted &&
          (library.autoSpeak || continuousTurn) &&
          speechSupported) {
        _replySpeech = speech.play(
          assistantTurn,
          assistantTurn.text,
          voice: library.speechVoice,
          speed: library.speechSpeed,
        );
        unawaited(_replySpeech!);
      }
      sent = true;
    } on ModelServiceException catch (error) {
      if (mounted && current == generation) {
        if (liveStarted) unawaited(speech.stop());
        setState(() => status = error.message);
      }
    } catch (_) {
      if (mounted && current == generation) {
        if (liveStarted) unawaited(speech.stop());
        setState(() => status = '请求失败；消息已保留，可以手动重试。');
      }
    } finally {
      if (liveSentences != null && !liveSentences!.isClosed) {
        unawaited(liveSentences!.close());
      }
      if (mounted && current == generation) {
        dialogueGuidance.cancel();
        setState(() {
          busy = false;
          active = null;
        });
        syncBackground();
      }
    }
    return sent;
  }

  void cancel() {
    controlConversation.clearProposal();
    if (continuous.enabled) unawaited(continuous.end());
    generation++;
    streamingText.value = '';
    unawaited(speech.stop());
    active?.cancel();
    planner?.cancel();
    dialogueGuidance.cancel();
    pendingReplyGuidance = '';
    waves.stop();
    unawaited(physical.stop());
    transcriber?.cancel();
    transcriber = null;
    recorder.discard();
    active = null;
    setState(() {
      busy = false;
      showRecording = false;
      status = '已停止本轮并丢弃录音；已发送的请求仍可能由供应商计费';
    });
    syncBackground();
  }

  String displayStatus(String message) {
    if (developerAccess) return message;
    if (message.startsWith('收到回复')) return '已收到回复';
    if (message.startsWith('已停止本轮')) return '本轮已停止，录音已丢弃';
    if (RegExp(
      r'诊断|API|密钥|Venice|HTTP|中继|xAI|模型|接口|token|格式',
      caseSensitive: false,
    ).hasMatch(message)) {
      return '服务暂时不可用，请稍后重试；仍有问题可联系管理员。';
    }
    return message;
  }

  Future<void> logout() async {
    if (loggingOut || widget.onLogout == null) return;
    setState(() => loggingOut = true);
    cancel();
    try {
      await Future.wait([
        continuous.end(),
        speech.stop(clearCache: true),
        physical.release(),
      ]);
      if (!mounted) return;
      if (physical.unknown) {
        setState(() => status = '设备停止尚未确认，请先在 DG-LAB 或设备上停止，再重试退出。');
        return;
      }
      deviceLinkActive = false;
      disconnectDeviceSignal.value++;
      await background.update(active: false);
      if (!mounted) return;
      widget.onLogout!();
    } catch (_) {
      if (mounted) setState(() => status = '停止任务未完成，请稍后重试退出登录。');
    } finally {
      if (mounted) setState(() => loggingOut = false);
    }
  }

  @override
  void dispose() {
    generation++;
    dialogueGuidance.cancel();
    continuous.removeListener(continuousChanged);
    continuous.dispose();
    speech.removeListener(speechChanged);
    speech.dispose();
    streamingText.dispose();
    waveTimer?.cancel();
    waves.removeListener(syncBackground);
    library.removeListener(preferencesChanged);
    library.dispose();
    background.dispose();
    disconnectDeviceSignal.dispose();
    chatScroll.dispose();
    pageController.dispose();
    planner?.cancel();
    physical.onFault = null;
    physical.dispose();
    if (widget.waveSession == null) waves.dispose();
    active?.cancel();
    transcriber?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    recorder.removeListener(recordingChanged);
    recorder.dispose();
    secret = null;
    model.dispose();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      AbsorbPointer(absorbing: loggingOut, child: buildWarm(context)),
      if (loggingOut)
        const Positioned.fill(
          child: ColoredBox(
            color: Color(0x88F8F4F0),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
    ],
  );
}
