import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'account_vault.dart';
import 'core_bridge.dart';
import 'local_owner.dart';
import 'voice_client.dart';
import 'venice_chat_page.dart';

class VoicePage extends StatefulWidget {
  const VoicePage({
    super.key,
    this.client,
    this.serviceAddress = const String.fromEnvironment('BETA_SERVICE_URL'),
    this.roleContext = '',
  });
  final VoiceClient? client;
  final String serviceAddress, roleContext;
  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> with WidgetsBindingObserver {
  late final VoiceClient voice;
  final vault = AccountVault();
  late final TextEditingController address;
  final invite = TextEditingController(), message = TextEditingController();
  bool busy = false, remember = true;
  String style = 'playful', notice = '';
  int duration = 60;
  double ceiling = 0.7;
  bool get localOwner => LocalOwner.eligible(address.text);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    voice = widget.client ?? VoiceClient(CoreBridge().call);
    address = TextEditingController(
      text: widget.serviceAddress.isEmpty
          ? 'http://127.0.0.1:8790'
          : widget.serviceAddress,
    );
    voice.addListener(changed);
    if (widget.client == null) unawaited(restore());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> restore() async {
    setState(() => busy = true);
    try {
      if (localOwner) {
        voice.api = await LocalOwner.connect(address.text);
        voice.status = '本机登录完成，可以连接语音';
        notice = '本机测试已就绪，无需邀请码';
        return;
      }
      final saved = await vault.load();
      if (!mounted) return;
      if (saved != null) {
        voice.api = saved;
        address.text = saved.base.toString();
        notice = '已恢复本机加密登录';
      }
    } catch (_) {
      if (mounted) {
        notice = localOwner
            ? '本机服务未就绪。请先运行“启动本机测试”，然后点击重试。'
            : '本机登录无法恢复，请联系项目方重新签发登录';
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() {
      busy = true;
      notice = '';
    });
    try {
      await work();
    } catch (_) {
      notice = '操作失败，请检查服务连接、账号权限或额度';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ([
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ].contains(state)) {
      unawaited(voice.pause(reason: 'window_${state.name}'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    voice.removeListener(changed);
    voice.dispose();
    address.dispose();
    invite.dispose();
    message.dispose();
    super.dispose();
  }

  Future<void> redeem() async {
    await voice.redeem(address.text, invite.text.trim());
    invite.clear();
    if (remember) {
      try {
        await vault.save(voice.api!);
        notice = '登录已由操作系统加密保存';
      } catch (_) {
        notice = '登录有效，但本机加密保存失败；关闭前请联系项目方保留账号访问';
      }
    }
  }

  Future<void> saveReport() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/voice-diagnostics.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(voice.diagnostics()),
      flush: true,
    );
    notice = '已保存不含对话和音频的诊断：${file.path}';
  }

  @override
  Widget build(BuildContext context) {
    final state =
        voice.core({'op': 'snapshot'})['state'] as Map<String, dynamic>;
    return Scaffold(
      appBar: AppBar(
        title: const Text('实时语音内测 · 模拟模式'),
        actions: [
          if (Platform.isWindows)
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      await voice.disconnect();
                      if (!context.mounted) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const VeniceChatPage(),
                        ),
                      );
                    },
              child: const Text('Venice 语音输入测试'),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: voice.stop,
            icon: const Icon(Icons.stop),
            label: const Text('立即停止并撤销模拟权限'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('项目方提供模型服务。音频仅在你开启麦克风后上传；本机不保存录音和对话。摄像头不启用。'),
              const SizedBox(height: 16),
              if (localOwner && voice.api == null) ...[
                const Text('Windows 本机测试 · 无需邀请码'),
                FilledButton(
                  onPressed: busy ? null : restore,
                  child: const Text('重试连接本机服务'),
                ),
              ] else if (voice.api == null) ...[
                if (widget.serviceAddress.isEmpty)
                  TextField(
                    controller: address,
                    decoration: const InputDecoration(labelText: '测试服务地址'),
                  ),
                TextField(
                  controller: invite,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '一次性邀请码 / 账号恢复码',
                  ),
                ),
                SwitchListTile(
                  title: const Text('在此设备加密保存登录'),
                  value: remember,
                  onChanged: busy ? null : (v) => setState(() => remember = v),
                ),
                FilledButton(
                  onPressed: busy ? null : () => run(redeem),
                  child: const Text('兑换并登录'),
                ),
              ] else ...[
                Text(
                  localOwner ? '本机测试 · 自动登录 · 不占内测名额' : '已登录 · 不需要供应商 API Key',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              final m = await voice.api!.request('/v1/me');
                              notice =
                                  '测试额度：${m['used']} / ${m['quota']} token（含在途预留）';
                            }),
                      child: const Text('查看额度'),
                    ),
                    if (!localOwner)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                await voice.disconnect();
                                await vault.clear();
                                voice.api = null;
                                notice = '已退出。本邀请码已经使用，重新登录需项目方签发恢复令牌。';
                              }),
                        child: const Text('退出并清除本机登录'),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: style,
                decoration: const InputDecoration(labelText: '对话风格'),
                items: const [
                  DropdownMenuItem(value: 'playful', child: Text('俏皮亲近')),
                  DropdownMenuItem(value: 'gentle', child: Text('温柔陪伴')),
                  DropdownMenuItem(value: 'technical', child: Text('技术对照')),
                ],
                onChanged: voice.probe.ready
                    ? null
                    : (v) => setState(() => style = v!),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: busy || voice.api == null || voice.probe.ready
                        ? null
                        : () => run(
                            () => voice.connect(
                              style: style,
                              roleContext: widget.roleContext,
                            ),
                          ),
                    child: const Text('连接 / 重新连接'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => run(voice.disconnect),
                    child: const Text('断开语音'),
                  ),
                ],
              ),
              Text(voice.status),
              if (voice.captureFailure != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(voice.captureFailure!.message),
                  ),
                ),
              SwitchListTile(
                title: const Text('使用耳机 · 允许语音插话'),
                subtitle: const Text(
                  '外放模式在 AI 播放时暂停上传，避免自触发；点“打断播报”后可说话。耳机模式与回声处理仍需真机试听。',
                ),
                value: voice.headphones,
                onChanged: voice.capturing
                    ? null
                    : (v) => setState(() => voice.headphones = v),
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: voice.probe.ready && !voice.starting
                        ? () => run(
                            voice.capturing ? voice.pause : voice.startMic,
                          )
                        : null,
                    icon: Icon(voice.capturing ? Icons.mic_off : Icons.mic),
                    label: Text(voice.capturing ? '暂停麦克风' : '开启麦克风并上传'),
                  ),
                  OutlinedButton(
                    onPressed: voice.probe.ready
                        ? () => run(voice.interrupt)
                        : null,
                    child: const Text('打断播报'),
                  ),
                ],
              ),
              Text(
                '${voice.capturing ? '麦克风开启 · 上传云端' : '麦克风关闭'} ｜ ${voice.speaker ? '正在播报' : '扬声器空闲'}',
              ),
              if (voice.capturing) ...[
                const SizedBox(height: 8),
                Text(
                  voice.captureChunks == 0
                      ? '等待麦克风输入…'
                      : '已收到麦克风数据 · ${voice.captureChunks} 个片段',
                ),
                LinearProgressIndicator(
                  value: voice.microphoneLevel.clamp(0, 1),
                ),
              ],
              const Divider(height: 24),
              const Text(
                '对话',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              if (voice.transcripts.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('连接后可以先发送文字确认回复，再开启麦克风说话。回复会显示在这里。'),
                ),
              ...voice.transcripts.map(
                (m) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SelectableText(
                    '${m['speaker'] == 'user' ? '你' : '小岚'}：${m['text']}',
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: message,
                      decoration: const InputDecoration(
                        labelText: '输入消息',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: voice.probe.ready ? (_) => sendText() : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: voice.probe.ready ? sendText : null,
                    child: const Text('发送'),
                  ),
                ],
              ),
              const Divider(height: 32),
              ExpansionTile(
                title: const Text('本次自主模拟授权'),
                subtitle: Text(
                  voice.capturing ? '可展开查看本次设置' : '先开启麦克风；此设置不影响文字聊天',
                ),
                children: [
                  const Text(
                    'AI 可在本次时段内安排波形和增减强度。停止、后台、断线或到期后必须重新授权。此入口无法驱动实物。',
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: duration,
                    decoration: const InputDecoration(labelText: '允许的时段'),
                    items: const [
                      DropdownMenuItem(value: 30, child: Text('30 秒')),
                      DropdownMenuItem(value: 60, child: Text('60 秒')),
                      DropdownMenuItem(value: 120, child: Text('120 秒')),
                    ],
                    onChanged: voice.simulation.active
                        ? null
                        : (v) => setState(() => duration = v!),
                  ),
                  Text('相对强度上限 ${(ceiling * 100).round()}% · 模拟硬上限 30%'),
                  Slider(
                    value: ceiling,
                    min: 0.5,
                    max: 1,
                    divisions: 5,
                    onChanged: voice.simulation.active
                        ? null
                        : (v) => setState(() => ceiling = v),
                  ),
                  FilledButton(
                    onPressed:
                        voice.capturing &&
                            voice.probe.ready &&
                            !voice.simulation.active
                        ? () => voice.authorize(
                            seconds: duration,
                            ceiling: ceiling,
                          )
                        : null,
                    child: Text('批准 $duration 秒自主模拟'),
                  ),
                  Text(
                    '${voice.simulation.status} · 剩余 ${voice.simulation.remaining} 秒 · 待执行 ${voice.simulation.queued} 步',
                  ),
                  if (voice.simulation.active &&
                      !voice.simulation.planningEnabled)
                    TextButton(
                      onPressed: voice.resumePlan,
                      child: const Text('在本次权限内继续由 AI 安排'),
                    ),
                  Text(
                    '目标 ${((state['gain_target'] as num? ?? 0) * 100).round()}% ｜ ${state['phase']}',
                  ),
                  LinearProgressIndicator(
                    value: ((state['output'] as List?)?.first as num? ?? 0)
                        .toDouble()
                        .clamp(0, 1),
                  ),
                  Text(voice.receiptText),
                ],
              ),
              TextButton(
                onPressed: () => run(saveReport),
                child: const Text('保存不含正文的诊断'),
              ),
              if (notice.isNotEmpty) SelectableText(notice),
            ],
          ),
        ),
      ),
    );
  }

  void sendText() {
    if (!voice.probe.ready || message.text.trim().isEmpty) return;
    voice.text(message.text);
    message.clear();
  }
}
