part of 'venice_chat_page.dart';

extension _WarmChatView on _VeniceChatPageState {
  void scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && chatScroll.hasClients) {
        chatScroll.animateTo(
          chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> editName() async {
    if (!library.ready || busy) return;
    final controller = TextEditingController(text: library.aiName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => Theme(
        data: warmTheme(),
        child: AlertDialog(
          title: const Text('给 AI 起个名字'),
          content: TextField(
            key: const Key('ai_name_input'),
            controller: controller,
            autofocus: true,
            maxLength: 20,
            decoration: const InputDecoration(hintText: '例如：小岚'),
            inputFormatters: [
              FilteringTextInputFormatter.deny(RegExp(r'[\x00-\x1F\x7F]')),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('save_ai_name'),
              onPressed: () {
                final value = controller.text.trim();
                if (WarmLibrary.validName(value)) Navigator.pop(context, value);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (name != null && mounted) {
      library.aiName = name;
      await library.save();
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
  }

  Future<void> enableChat() async {
    final enabled = await showDialog<bool>(
      context: context,
      builder: (context) => Theme(
        data: warmTheme(),
        child: AlertDialog(
          title: const Text('开始与你的 AI 聊天'),
          content: Text(
            developerAccess
                ? '发送消息会将文字及最近对话交给 Venice；点击转写会上传本段录音。开启自动朗读后，回复文字也会交给 Venice 合成语音。这些请求会使用你配置的 API 额度。'
                : '发送消息会将文字和最近对话交给云端服务处理；语音转写会上传本段录音，自动朗读会将回复文字交给云端合成语音。你可以在设置中关闭在线对话或自动朗读。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('启用对话'),
            ),
          ],
        ),
      ),
    );
    if (enabled == true && mounted) {
      library.funded = true;
      await library.save();
    }
  }

  Widget buildWarm(BuildContext context) => Theme(
    data: warmTheme(),
    child: Builder(
      builder: (context) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarColor: warmPaper,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 700),
                child: Column(
                  children: [
                    Expanded(
                      child: PageView(
                        controller: pageController,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          _RetainedWarmPage(
                            child: TickerMode(
                              enabled: page == 0,
                              child: WarmInteractionPage(
                                developerAccess: developerAccess,
                                library: library,
                                physical: physical,
                                stop: cancel,
                                beforeStart: prepareBackground,
                                onConnectionActivity: connectionActivity,
                                disconnectSignal: disconnectDeviceSignal,
                              ),
                            ),
                          ),
                          _RetainedWarmPage(
                            child: TickerMode(
                              enabled: page == 1,
                              child: chatPage(context),
                            ),
                          ),
                          _RetainedWarmPage(child: settingsPage(context)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
              ? null
              : NavigationBar(
                  height: 60,
                  selectedIndex: page,
                  onDestinationSelected: (index) {
                    selectPage(index);
                  },
                  destinations: const [
                    NavigationDestination(
                      key: Key('nav_interaction'),
                      icon: Icon(Icons.graphic_eq_rounded),
                      label: '互动',
                    ),
                    NavigationDestination(
                      key: Key('nav_chat'),
                      icon: Icon(Icons.chat_bubble_outline_rounded),
                      selectedIcon: Icon(Icons.chat_bubble_rounded),
                      label: '聊天',
                    ),
                    NavigationDestination(
                      key: Key('nav_mine'),
                      icon: Icon(Icons.person_outline_rounded),
                      selectedIcon: Icon(Icons.person_rounded),
                      label: '我的',
                    ),
                  ],
                ),
        ),
      ),
    ),
  );

  Widget chatPage(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final compact =
          constraints.maxHeight < 480 ||
          constraints.maxHeight / textScale < 380;
      final header = Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            const RoseAvatar(size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: editName,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      library.aiName,
                      key: const Key('chat_ai_name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!compact)
                      const Text(
                        '此刻，陪你聊聊',
                        style: TextStyle(color: warmMuted, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
            if (speechSupported)
              IconButton(
                key: const Key('chat_auto_speak'),
                tooltip: continuous.enabled
                    ? '连续对话期间自动朗读'
                    : library.autoSpeak
                    ? '关闭自动朗读'
                    : '开启自动朗读',
                onPressed: library.ready && !continuous.enabled
                    ? () => setAutoSpeak(!library.autoSpeak)
                    : null,
                icon: Icon(
                  (library.autoSpeak || continuous.enabled)
                      ? Icons.volume_up_outlined
                      : Icons.volume_off_outlined,
                  size: 22,
                  color: warmRose,
                ),
              ),
            ListenableBuilder(
              listenable: waves,
              builder: (context, _) => Semantics(
                label: '当前模式',
                child: WarmBadge(
                  waves.physical && waves.active
                      ? '实物'
                      : developerAccess
                      ? '模拟'
                      : '待机',
                ),
              ),
            ),
            IconButton(
              key: const Key('venice_emergency_stop'),
              tooltip: '停止输出与本轮请求',
              onPressed: cancel,
              icon: const Icon(
                Icons.stop_circle_outlined,
                color: warmRose,
                size: 23,
              ),
            ),
          ],
        ),
      );
      final messages = <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: Text('本次对话', style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        if (turns.isEmpty && pendingText == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 10),
            child: Column(
              children: [
                const RoseAvatar(size: 66),
                const SizedBox(height: 20),
                Text(
                  '与${library.aiName}，慢慢聊',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  '打字，或用声音开始这次对话。',
                  style: TextStyle(color: warmMuted),
                ),
              ],
            ),
          ),
        for (final turn in turns) chatBubble(turn),
        if (pendingText != null) chatBubble(ChatTurn('user', pendingText!)),
        ValueListenableBuilder<String>(
          valueListenable: streamingText,
          builder: (context, text, _) => text.isEmpty
              ? const SizedBox.shrink()
              : chatBubble(
                  ChatTurn('assistant', text),
                  speechId: streamingMessageId,
                ),
        ),
        if (developerAccess &&
            pendingText != null &&
            pendingControlReceipt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '执行回执：$pendingControlReceipt',
              key: const Key('pending_control_receipt'),
              style: const TextStyle(fontSize: 11, color: warmMuted),
            ),
          ),
        if (pendingText != null && !busy)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('retry_message'),
              onPressed: () => send(retry: true),
              icon: const Icon(Icons.refresh),
              label: const Text('未完成 · 重试'),
            ),
          ),
        if (busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: Icon(Icons.hourglass_top_rounded, size: 14),
                ),
                SizedBox(width: 10),
                Text('正在处理，请稍候…', style: TextStyle(color: warmMuted)),
              ],
            ),
          ),
      ];
      final composer = chatComposer(context, compact: compact);
      return Column(
        children: [
          if (!compact) header,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .5,
              ),
              child: SingleChildScrollView(child: chatWaveControl(context)),
            ),
          ),
          Expanded(
            child: ListView(
              key: const Key('chat_messages'),
              controller: chatScroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: messages,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * (compact ? .42 : .45),
              ),
              child: SingleChildScrollView(child: composer),
            ),
          ),
        ],
      );
    },
  );

  Widget chatBubble(ChatTurn turn, {Object? speechId}) {
    final user = turn.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: user
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              margin: EdgeInsets.only(
                left: user ? 38 : 0,
                right: user ? 0 : 12,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: user ? warmRose : const Color(0xFFF0E5E5),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(19),
                  topRight: const Radius.circular(19),
                  bottomLeft: Radius.circular(user ? 19 : 5),
                  bottomRight: Radius.circular(user ? 5 : 19),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    turn.text,
                    semanticsLabel:
                        '${user ? '你' : library.aiName}：${turn.text}',
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.4,
                      color: user ? Colors.white : warmInk,
                    ),
                  ),
                  if (!user)
                    Row(
                      children: [
                        if (speechSupported)
                          SpeechMessageControl(
                            compact: true,
                            output: speech,
                            message: speechId ?? turn,
                            onPlay: !occupied && funded && secret != null
                                ? () => speakTurn(turn)
                                : null,
                          ),
                        if (developerAccess && controlReceipts[turn] != null)
                          Expanded(
                            child: InkWell(
                              onTap: () => showDialog<void>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('实际执行结果'),
                                  content: Text(controlReceipts[turn]!),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('关闭'),
                                    ),
                                  ],
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Text(
                                  '执行回执：${controlReceipts[turn]}',
                                  key: const Key('chat_control_receipt'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: warmMuted,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  if (!user && speechSupported)
                    ListenableBuilder(
                      listenable: speech,
                      builder: (context, _) =>
                          identical(speech.message, speechId ?? turn) &&
                              speech.phase == SpeechOutputPhase.failed
                          ? Text(
                              displayStatus(speech.error),
                              key: const Key('speech_error'),
                              style: const TextStyle(
                                fontSize: 11,
                                color: warmRose,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget chatWaveControl(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([waves, physical]),
    builder: (context, _) => WarmCard(
      key: const Key('chat_persistent_control'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      library.name(waves.wave),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      waves.active
                          ? '${waves.physical ? "实物运行中" : "模拟 · 不限时"} · 上限 ${waves.cap}'
                          : '未运行 · 请在互动页开始',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: warmMuted),
                    ),
                  ],
                ),
              ),
              TextButton(
                key: const Key('chat_change_wave'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (context) => SafeArea(
                    child: SizedBox(
                      height: MediaQuery.sizeOf(context).height * .8,
                      child: WarmWaveLibraryPage(
                        library: library,
                        embedded: true,
                        onSelected: () => Navigator.pop(context),
                      ),
                    ),
                  ),
                ),
                child: const Text('换波形'),
              ),
              IconButton(
                key: const Key('chat_strength_limits'),
                tooltip: '强度设置 · 上限 ${waves.cap} · 最大增幅 ${waves.maxIncrease}',
                onPressed: () => showStrengthLimits(
                  context,
                  library,
                  physical,
                  developerAccess: developerAccess,
                ),
                icon: const Icon(Icons.tune_rounded, size: 20),
              ),
              IconButton(
                key: const Key('chat_stop_output'),
                tooltip: '停止输出与本轮请求',
                onPressed: cancel,
                icon: const Icon(Icons.stop_circle_outlined, size: 22),
              ),
            ],
          ),
          if (physical.ble case final link? when developerAccess)
            Text(
              physical.unknown
                  ? physical.status
                  : '蓝牙报告 A ${link.actualA ?? '—'} / B ${link.actualB ?? '—'} · 下方为目标值',
              style: const TextStyle(fontSize: 10, color: warmMuted),
            ),
          WarmPlayback(session: waves, height: 16),
          Row(
            children: [
              for (final i in [0, 1])
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        i == 0 ? 'A' : 'B',
                        style: const TextStyle(fontSize: 12),
                      ),
                      Expanded(
                        child: IconButton(
                          key: Key('chat_channel_${i}_minus'),
                          tooltip:
                              '通道 ${i == 0 ? "A" : "B"} 减少 ${waves.manualStep}',
                          onPressed: waves.active
                              ? () => adjustWarmChannel(
                                  waves,
                                  i,
                                  -waves.manualStep,
                                )
                              : null,
                          icon: const Icon(Icons.remove, size: 18),
                        ),
                      ),
                      Text(
                        '${waves.strength[i]}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      Expanded(
                        child: IconButton(
                          key: Key('chat_channel_${i}_plus'),
                          tooltip:
                              '通道 ${i == 0 ? "A" : "B"} 增加 ${waves.manualStep}',
                          onPressed: waves.active
                              ? () => adjustWarmChannel(
                                  waves,
                                  i,
                                  waves.manualStep,
                                )
                              : null,
                          icon: const Icon(Icons.add, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget chatComposer(
    BuildContext context, {
    required bool compact,
  }) => ListenableBuilder(
    listenable: waves,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!funded || secret == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  secret == null
                      ? (keyLoading ? '正在准备服务…' : '服务配置需要处理')
                      : '对话准备就绪',
                  style: const TextStyle(fontSize: 12, color: warmMuted),
                ),
                TextButton(
                  onPressed: secret == null ? () => selectPage(2) : enableChat,
                  child: Text(secret == null ? '查看设置' : '启用对话'),
                ),
              ],
            ),
          ),
        if (status != '准备就绪后，可录音或输入文字。')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: GestureDetector(
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('本轮状态'),
                  content: Text(displayStatus(status)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('知道了'),
                    ),
                  ],
                ),
              ),
              child: Text(
                displayStatus(status),
                key: const Key('venice_status'),
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: warmMuted),
              ),
            ),
          ),
        const SizedBox(height: 8),
        WarmCard(
          padding: const EdgeInsets.fromLTRB(5, 4, 5, 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (speechSupported && !continuous.enabled)
                ListenableBuilder(
                  listenable: speech,
                  builder: (context, _) => !speech.active
                      ? const SizedBox.shrink()
                      : Padding(
                          key: const Key('speech_now_playing'),
                          padding: const EdgeInsets.only(left: 12),
                          child: Row(
                            children: [
                              VoiceBars(
                                playing:
                                    speech.phase == SpeechOutputPhase.playing,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  speech.phase == SpeechOutputPhase.generating
                                      ? '正在准备语音…'
                                      : '${library.aiName}正在朗读',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: warmRose,
                                  ),
                                ),
                              ),
                              IconButton(
                                key: const Key('stop_speech'),
                                tooltip: '停止朗读',
                                onPressed: continuous.enabled
                                    ? () => continuous.pause()
                                    : speech.stop,
                                icon: const Icon(
                                  Icons.stop_circle_outlined,
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              if (continuous.enabled)
                continuousPanel()
              else if (speechSupported)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('continuous_start'),
                    onPressed: !occupied && funded && secret != null
                        ? openContinuous
                        : null,
                    icon: const Icon(Icons.headset_mic_outlined, size: 18),
                    label: const Text('连续对话'),
                  ),
                ),
              if (showRecording && !continuous.enabled) recordingPanel(context),
              if (!continuous.enabled)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      key: const Key('show_recording'),
                      tooltip: '语音输入',
                      onPressed: continuous.enabled
                          ? null
                          : () => updateView(
                              () => showRecording = !showRecording,
                            ),
                      icon: Icon(
                        showRecording
                            ? Icons.keyboard_outlined
                            : Icons.mic_none_rounded,
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        key: const Key('venice_message'),
                        controller: input,
                        enabled: !occupied && !continuous.enabled,
                        minLines: 1,
                        maxLines: compact ? 2 : 3,
                        maxLength: 2000,
                        decoration: const InputDecoration(
                          hintText: '说点什么…',
                          counterText: '',
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                        onSubmitted: (_) => send(),
                      ),
                    ),
                    const SizedBox(width: 3),
                    IconButton.filled(
                      key: const Key('venice_send'),
                      tooltip: '发送',
                      onPressed:
                          !occupied &&
                              !continuous.enabled &&
                              funded &&
                              secret != null
                          ? send
                          : null,
                      icon: const Icon(Icons.send_rounded, size: 22),
                    ),
                  ],
                ),
              if (!compact && !continuous.enabled)
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Text(
                    '语音将转为文字',
                    style: TextStyle(fontSize: 10, color: warmMuted),
                  ),
                ),
              if (busy && !continuous.enabled)
                TextButton(onPressed: cancel, child: const Text('取消等待')),
            ],
          ),
        ),
      ],
    ),
  );

  Widget recordingPanel(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          switch (recorder.phase) {
            RecordingPhase.starting => '正在申请麦克风权限…',
            RecordingPhase.recording =>
              '正在录音 · ${recorder.seconds.toStringAsFixed(1)} 秒（未上传）',
            RecordingPhase.stopping => '正在关闭麦克风…',
            RecordingPhase.ready =>
              '录音就绪 · ${recorder.seconds.toStringAsFixed(1)} 秒',
            RecordingPhase.failed => recorder.error,
            RecordingPhase.idle => '麦克风关闭 · 最长 60 秒',
          },
          key: const Key('venice_recording_status'),
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (!recorder.capturing)
              FilledButton.icon(
                key: const Key('venice_record'),
                onPressed: !occupied ? startRecording : null,
                icon: const Icon(Icons.mic_none),
                label: const Text('开始录音'),
              ),
            if (recorder.capturing || recorder.phase == RecordingPhase.ready)
              FilledButton(
                key: const Key('venice_transcribe'),
                onPressed: busy || keyLoading
                    ? null
                    : funded && secret != null
                    ? transcribeRecording
                    : recorder.capturing
                    ? recorder.stop
                    : null,
                child: Text(
                  recorder.capturing
                      ? (funded && secret != null ? '停止并转写' : '停止录音')
                      : '转写此段录音',
                ),
              ),
            if (recorder.busy || recorder.phase == RecordingPhase.ready || busy)
              TextButton(
                key: const Key('venice_discard'),
                onPressed: cancel,
                child: const Text('取消本轮'),
              ),
          ],
        ),
        if (transcript.isNotEmpty && !busy)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '已识别：$transcript',
              key: const Key('venice_transcript'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: warmMuted),
            ),
          ),
      ],
    ),
  );

  Widget settingsPage(BuildContext context) => ListView(
    padding: const EdgeInsets.all(22),
    children: [
      Text('我的', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 24),
      WarmCard(
        child: Row(
          children: [
            const RoseAvatar(size: 58),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    library.aiName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Text(
                    '你的 AI 聊天伙伴',
                    style: TextStyle(fontSize: 12, color: warmMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const Key('edit_ai_name'),
              tooltip: '修改 AI 名字',
              onPressed: busy || !library.ready ? null : editName,
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      WarmCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            SwitchListTile(
              key: const Key('venice_funded'),
              value: funded,
              onChanged: occupied || !library.ready
                  ? null
                  : (v) {
                      library.funded = v;
                      if (!v) unawaited(speech.stop(clearCache: true));
                      library.save();
                    },
              title: const Text('启用在线对话'),
              subtitle: Text(
                developerAccess ? '发送文字或转写录音时使用 API 额度' : '使用云端服务处理对话与语音',
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile(
              key: const Key('venice_auto_send'),
              value: autoSend,
              onChanged: occupied
                  ? null
                  : (v) {
                      library.autoSend = v;
                      library.save();
                    },
              title: const Text('转写后自动发送'),
              subtitle: const Text('关闭后可先修改识别文字'),
            ),
          ],
        ),
      ),
      if (speechSupported) ...[
        const SizedBox(height: 20),
        WarmCard(
          key: const Key('speech_settings'),
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SwitchListTile(
                key: const Key('auto_speak'),
                value: library.autoSpeak || continuous.enabled,
                onChanged: library.ready && !continuous.enabled
                    ? setAutoSpeak
                    : null,
                title: const Text('自动朗读回复'),
                subtitle: const Text('可随时停止；开始录音会打断朗读'),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                key: const Key('speech_voice'),
                leading: const Icon(Icons.record_voice_over_outlined),
                title: const Text('朗读音色'),
                subtitle: Text(speechVoiceLabels[library.speechVoice]!),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => chooseSpeechVoice(context),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('语速 ${library.speechSpeed.toStringAsFixed(1)}×'),
                    Slider(
                      key: const Key('speech_speed'),
                      value: library.speechSpeed,
                      min: .7,
                      max: 1.5,
                      divisions: 8,
                      label: '${library.speechSpeed.toStringAsFixed(1)}×',
                      onChanged: (value) {
                        updateView(() => library.speechSpeed = value);
                      },
                      onChangeEnd: (_) {
                        unawaited(speech.stop());
                        unawaited(library.save());
                      },
                    ),
                    Text(
                      developerAccess
                          ? 'xAI TTS v1 · 朗读使用 Venice 额度。失败时可手动重试，文字回复会保留。'
                          : '朗读失败时可手动重试，文字回复会保留。',
                      style: TextStyle(fontSize: 12, color: warmMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
      if (developerAccess) ...[
        const SizedBox(height: 20),
        WarmCard(
          padding: EdgeInsets.zero,
          child: ListTile(
            key: const Key('connection_diagnostics'),
            leading: const Icon(Icons.network_check),
            title: const Text('控制与对话诊断'),
            subtitle: Text(VeniceRoute.connectionLabel),
            trailing: const Icon(Icons.chevron_right),
            onTap: openDiagnostics,
          ),
        ),
      ],
      const SizedBox(height: 20),
      WarmCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('后台互动', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '切换 App 或锁屏后，已开始的聊天请求、朗读、波形和录音继续运行。安卓通知栏可停止全部任务。',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(
              developerAccess
                  ? '每段录音最多 60 秒；模拟和实物均不限总时长。系统强制结束 App、设备断线或故障停止后不自动恢复。'
                  : '每段录音最多 60 秒。系统强制结束 App、设备断线或故障停止后不自动恢复，需要重新开始。',
              style: TextStyle(fontSize: 12, color: warmMuted),
            ),
          ],
        ),
      ),
      if (developerAccess) ...[
        const SizedBox(height: 20),
        WarmCard(
          padding: EdgeInsets.zero,
          child: ExpansionTile(
            title: const Text('模型与服务'),
            leading: const Icon(Icons.tune_rounded),
            childrenPadding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Venice Uncensored 1.2 · 文字\nxAI Speech to Text v1 · 转写\nxAI TTS v1 · 朗读',
              ),
              const SizedBox(height: 12),
              Text(keyStatus, key: const Key('venice_key_status')),
              TextButton(
                key: const Key('venice_reload_key'),
                onPressed: occupied ? null : load,
                child: const Text('重新读取密钥'),
              ),
              TextField(
                key: const Key('venice_model'),
                controller: model,
                enabled: !occupied && !continuous.enabled,
                maxLength: 120,
                decoration: const InputDecoration(labelText: '文字模型 ID'),
              ),
              SelectableText(
                VeniceRoute.base.toString(),
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 16),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.delete_outline),
        title: const Text('清空本轮对话'),
        subtitle: const Text('对话仅在当前运行期间保留'),
        onTap: occupied
            ? null
            : () async {
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('清空本轮对话？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('保留'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                );
                if (yes == true && mounted) {
                  await speech.stop(clearCache: true);
                  if (!mounted) return;
                  updateView(() {
                    turns.clear();
                    controlConversation.clear();
                    pendingExecution = null;
                    controlReceipts.clear();
                    pendingControlReceipt = null;
                    pendingText = null;
                    transcript = '';
                    input.clear();
                  });
                }
              },
      ),
      const SizedBox(height: 16),
      if (developerAccess)
        Text(
          library.notice,
          style: const TextStyle(fontSize: 12, color: warmMuted),
        ),
      const Text(
        'AI Haptics · 暖雾\n${String.fromEnvironment('APP_VERSION', defaultValue: '开发版')}',
        style: TextStyle(fontSize: 12, color: warmMuted),
      ),
      const SizedBox(height: 8),
      if (developerAccess)
        Text(
          widget.selfHosted
              ? '开源自部署版 · 使用你自己的服务'
              : VeniceRoute.isCloudRelay
              ? '云中继内测版'
              : VeniceRoute.isRelay
              ? '局域网中继测试版 · 仅连接配置的电脑'
              : VeniceLocalKey.isEmbedded
              ? '个人测试版 · 内置个人测试密钥，请勿分发。'
              : '本机测试版',
          style: const TextStyle(fontSize: 12, color: warmMuted),
        ),
      const SizedBox(height: 8),
      const Text(
        '录音只保留在内存中，转写成功、取消或退出后丢弃。名称、分类和收藏保存在本机。',
        style: TextStyle(fontSize: 12, color: warmMuted),
      ),
      if (widget.onLogout != null) ...[
        const SizedBox(height: 20),
        ListTile(
          key: const Key('pilot_logout'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.logout_rounded),
          title: Text(widget.selfHosted ? '返回服务配置' : '退出登录'),
          subtitle: Text(
            widget.selfHosted
                ? '自部署 · 配置仅在当前运行内保存'
                : developerAccess
                ? '当前身份：管理员'
                : '当前身份：内测用户',
          ),
          onTap: loggingOut ? null : logout,
        ),
      ],
    ],
  );

  Future<void> chooseSpeechVoice(BuildContext context) async {
    final voice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('选择朗读音色'),
                subtitle: Text('更换后，下一次朗读使用新音色'),
              ),
              for (final item in speechVoiceLabels.entries)
                ListTile(
                  key: Key('speech_voice_${item.key}'),
                  title: Text(item.value),
                  trailing: library.speechVoice == item.key
                      ? const Icon(Icons.check, color: warmRose)
                      : null,
                  onTap: () => Navigator.pop(context, item.key),
                ),
            ],
          ),
        ),
      ),
    );
    if (voice == null || !mounted || voice == library.speechVoice) return;
    await speech.stop();
    if (!mounted) return;
    library.speechVoice = voice;
    await library.save();
  }
}

// Keep tab state without laying out every off-screen page during IME animation.
class _RetainedWarmPage extends StatefulWidget {
  const _RetainedWarmPage({required this.child});
  final Widget child;
  @override
  State<_RetainedWarmPage> createState() => _RetainedWarmPageState();
}

class _RetainedWarmPageState extends State<_RetainedWarmPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
