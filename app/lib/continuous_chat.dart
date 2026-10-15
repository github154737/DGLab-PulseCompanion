part of 'venice_chat_page.dart';

extension _ContinuousChat on _VeniceChatPageState {
  void continuousChanged() {
    if (!mounted) return;
    updateView(() {});
    syncBackground();
  }

  Future<bool> prepareContinuous() async {
    if (!mounted || !continuous.running) return false;
    _continuousReady = true;
    return background.update(
      active: true,
      microphone: true,
      continuous: true,
      device: deviceLinkActive || waves.physical && waves.active,
      simulation: waves.active && !waves.physical,
    );
  }

  Future<String> transcribeContinuous(Uint8List wav) async {
    final current = ++generation;
    transcriber =
        widget.transcriberFactory?.call(secret!) ??
        VeniceTranscriber(apiKey: secret!);
    String text;
    try {
      text = await transcriber!.transcribe(wav);
    } on NoSpeechDetected {
      text = '';
    }
    if (!mounted || current != generation || !continuous.running) {
      throw StateError('cancelled');
    }
    transcriber = null;
    final echo = _interruptedSpeech;
    _interruptedSpeech = '';
    if (resemblesPlaybackEcho(text, echo)) {
      // A conservative guard, not proof of speaker identity. Do not turn a
      // likely loudspeaker echo into a device command or another AI turn.
      unawaited(continuous.pause('疑似收录了刚才的朗读，已暂停。请降低外放音量或佩戴耳机后继续。'));
      throw StateError('playback_echo');
    }
    return text;
  }

  Future<void> interruptContinuousReply() async {
    _interruptedSpeech = speech.phase == SpeechOutputPhase.playing
        ? speech.currentText
        : '';
    // Preserve the interrupted turn and its real control receipt for the user.
    if (pendingText != null) {
      turns.add(ChatTurn('user', pendingText!));
      if (streamingText.value.isNotEmpty) {
        final partial = ChatTurn('assistant', streamingText.value);
        turns.add(partial);
        if (pendingControlReceipt != null) {
          controlReceipts[partial] = pendingControlReceipt!;
        }
      }
      if (turns.length > 24) turns.removeRange(0, turns.length - 24);
      controlReceipts.removeWhere((turn, _) => !turns.contains(turn));
      pendingText = null;
    }
    pendingControlReceipt = null;
    pendingExecution = null;
    controlConversation.clearProposal();
    await cancelContinuousWork(keepMicrophone: true);
  }

  Future<void> replyContinuous(String text) async {
    if (!mounted || !continuous.running) return;
    input.text = text;
    final success = await send(continuousTurn: true);
    if (!success) throw StateError('reply_failed');
    await _replySpeech;
    if (speech.phase == SpeechOutputPhase.failed) {
      throw ContinuousPlaybackFailure(
        speech.failureCode,
        recoverable: !const {
          'tts_http_401',
          'tts_http_402',
          'tts_http_403',
          'tts_http_429',
          'playback_device',
        }.contains(speech.failureCode),
      );
    }
  }

  Future<void> cancelContinuousWork({bool keepMicrophone = false}) async {
    controlConversation.clearProposal();
    generation++;
    active?.cancel();
    active = null;
    planner?.cancel();
    planner = null;
    dialogueGuidance.cancel();
    pendingReplyGuidance = '';
    transcriber?.cancel();
    transcriber = null;
    // Voice authority is independent of existing physical-session authorization.
    // No cancelled response may later apply a control command.
    if (mounted) {
      streamingText.value = '';
      updateView(() {
        busy = false;
      });
    }
    await speech.stop();
    if (!keepMicrophone) {
      _continuousReady = false;
      _interruptedSpeech = '';
    }
    if (mounted) syncBackground();
  }

  Future<void> openContinuous() async {
    if (occupied ||
        !funded ||
        secret == null ||
        !speechSupported ||
        continuous.enabled) {
      return;
    }
    var allowBackground = false;
    var bargeIn = true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('开启连续对话'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '说完停顿后自动转写并回复。开启“开口打断”后，朗读时麦克风也会监听，检测到持续说话会停止当前回复；声音先在手机判断，成句后才上传。静音或结束会关闭麦克风。对话会使用 API 额度。',
                ),
                CheckboxListTile(
                  key: const Key('continuous_barge_in'),
                  value: bargeIn,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开口打断朗读'),
                  subtitle: const Text('需回声消除或耳机；外放误触发时可关闭'),
                  onChanged: (value) => update(() => bargeIn = value ?? true),
                ),
                CheckboxListTile(
                  key: const Key('continuous_background'),
                  value: allowBackground,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('锁屏或切后台后继续'),
                  subtitle: const Text('通知栏可静音或结束；可能增加耗电'),
                  onChanged: (value) =>
                      update(() => allowBackground = value ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('continuous_confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开启麦克风'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted || !_appForeground) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await speech.stop();
    await recorder.discard();
    if (!mounted) return;
    updateView(() => showRecording = false);
    continuous.allowBackground = allowBackground;
    continuous.bargeIn = bargeIn;
    if (continuous.capture case NativeSpeechCapture capture) {
      capture.duplex = bargeIn;
    }
    await continuous.start();
  }

  Future<void> resumeContinuous() async {
    if (!_appForeground || !mounted || !funded || secret == null) return;
    await continuous.start();
  }

  Future<void> interruptContinuous() async {
    await continuous.pause('已打断朗读');
    if (mounted && _appForeground) await continuous.start();
  }

  Widget continuousPanel() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (continuous.phase == ContinuousPhase.speaking)
              const VoiceBars(playing: true)
            else
              Icon(
                continuous.phase == ContinuousPhase.listening
                    ? Icons.mic
                    : Icons.headset_mic_outlined,
                color: warmRose,
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                switch (continuous.phase) {
                  ContinuousPhase.off => '连续对话',
                  ContinuousPhase.starting => '正在开启麦克风…',
                  ContinuousPhase.listening => '正在听 · 说完停顿即可发送',
                  ContinuousPhase.transcribing =>
                    continuous.bargeIn ? '正在识别 · 暂不接收新一句' : '正在识别 · 麦克风已关闭',
                  ContinuousPhase.replying =>
                    continuous.bargeIn ? '正在回复 · 可开口打断' : '正在回复 · 麦克风已关闭',
                  ContinuousPhase.speaking =>
                    continuous.bargeIn ? '正在朗读 · 可开口打断' : '正在朗读 · 麦克风已关闭',
                  ContinuousPhase.paused => '已暂停 · 麦克风已关闭',
                },
                key: const Key('continuous_status'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        if (continuous.notice.isNotEmpty)
          Text(
            continuous.notice,
            style: const TextStyle(fontSize: 11, color: warmMuted),
          ),
        Wrap(
          spacing: 4,
          children: [
            if (continuous.phase == ContinuousPhase.paused)
              TextButton(
                key: const Key('continuous_resume'),
                onPressed: resumeContinuous,
                child: const Text('继续'),
              )
            else
              TextButton(
                key: const Key('continuous_mute'),
                onPressed: continuous.pause,
                child: const Text('静音'),
              ),
            if (continuous.phase == ContinuousPhase.speaking ||
                continuous.phase == ContinuousPhase.replying)
              TextButton(
                key: const Key('continuous_interrupt'),
                onPressed: interruptContinuous,
                child: const Text('打断并说话'),
              ),
            TextButton(
              key: const Key('continuous_end'),
              onPressed: continuous.end,
              child: const Text('结束对话'),
            ),
          ],
        ),
      ],
    ),
  );
}
