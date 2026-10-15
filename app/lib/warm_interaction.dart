import 'dart:async';

import 'package:flutter/material.dart';

import 'connection_panel.dart';
import 'physical_output.dart';
import 'venice_wave_session.dart';
import 'warm_library.dart';
import 'warm_theme.dart';
import 'warm_playback.dart';
import 'warm_wave_pages.dart';
import 'warm_strength_limits.dart';

void adjustWarmChannel(VeniceWaveSession s, int channel, int step) {
  if (!s.active) return;
  s.invalidate('manual_strength');
  final next = List<int>.of(s.strength);
  next[channel] = (next[channel] + step).clamp(0, s.cap);
  s.apply({
    'action': 'set',
    'a': next[0],
    'b': next[1],
    'waveform_id': s.selected,
  }, s.epoch);
}

class WarmControlCard extends StatelessWidget {
  const WarmControlCard({
    super.key,
    required this.library,
    this.compact = false,
    this.onLimits,
    this.physical,
    this.developerAccess = false,
  });
  final WarmLibrary library;
  final bool compact;
  final VoidCallback? onLimits;
  final PhysicalOutput? physical;
  final bool developerAccess;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([library.session, ?physical]),
    builder: (context, _) {
      final s = library.session;
      return WarmCard(
        padding: EdgeInsets.all(compact ? 10 : 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    library.name(s.wave),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 6),
                WarmBadge(s.active ? '播放中' : '待机'),
              ],
            ),
            const SizedBox(height: 6),
            if (developerAccess && physical?.ble != null)
              Text(
                physical!.unknown
                    ? physical!.status
                    : '蓝牙开发版 · 设备报告 A ${physical!.ble!.actualA ?? '—'} / B ${physical!.ble!.actualB ?? '—'}',
                style: const TextStyle(fontSize: 11, color: warmMuted),
              ),
            if (!developerAccess && physical?.unknown == true)
              const Text(
                '设备状态未确认，请停止输出并检查连接。',
                style: TextStyle(fontSize: 11, color: warmMuted),
              ),
            WarmPlayback(session: s, height: compact ? 34 : 52),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.active
                          ? '${s.physical ? '设备目标' : '模拟播放'} · 非实测电流'
                          : '静态预览 · 强度为零',
                      style: const TextStyle(fontSize: 10, color: warmMuted),
                    ),
                  ),
                  if (onLimits != null)
                    InkWell(
                      onTap: onLimits,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          '上限 ${s.cap} · 设置',
                          style: const TextStyle(fontSize: 11, color: warmRose),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (!s.wave.deviceReady && s.active)
              const Text(
                '导入形状动画 · 播放时序待核验',
                style: TextStyle(fontSize: 10, color: warmMuted),
              ),
            LayoutBuilder(
              builder: (context, c) {
                final items = List.generate(
                  2,
                  (i) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5ECEC),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${i == 0 ? 'A' : 'B'} 通道',
                          style: const TextStyle(fontSize: 11),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(
                              key: Key('channel_${i}_minus'),
                              tooltip:
                                  '${i == 0 ? 'A' : 'B'} 减少 ${s.manualStep}',
                              onPressed: s.active
                                  ? () => adjustWarmChannel(s, i, -s.manualStep)
                                  : null,
                              icon: const Icon(Icons.remove, size: 20),
                              constraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 40,
                              ),
                              padding: EdgeInsets.zero,
                            ),
                            Flexible(
                              child: FittedBox(
                                child: Text(
                                  '${s.strength[i]}',
                                  key: Key('warm_channel_$i'),
                                  style: const TextStyle(
                                    fontSize: 23,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              key: Key('channel_${i}_plus'),
                              tooltip:
                                  '${i == 0 ? 'A' : 'B'} 增加 ${s.manualStep}',
                              onPressed: s.active
                                  ? () => adjustWarmChannel(s, i, s.manualStep)
                                  : null,
                              icon: const Icon(Icons.add, size: 20),
                              constraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 40,
                              ),
                              padding: EdgeInsets.zero,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
                return c.maxWidth < 230
                    ? Column(
                        children: [
                          items[0],
                          const SizedBox(height: 6),
                          items[1],
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: items[0]),
                          const SizedBox(width: 8),
                          Expanded(child: items[1]),
                        ],
                      );
              },
            ),
          ],
        ),
      );
    },
  );
}

class WarmInteractionPage extends StatefulWidget {
  const WarmInteractionPage({
    super.key,
    required this.library,
    required this.physical,
    required this.stop,
    required this.beforeStart,
    this.onConnectionActivity,
    this.disconnectSignal,
    this.developerAccess = false,
  });
  final WarmLibrary library;
  final PhysicalOutput physical;
  final VoidCallback stop;
  final Future<bool> Function() beforeStart;
  final Future<bool> Function(bool)? onConnectionActivity;
  final Listenable? disconnectSignal;
  final bool developerAccess;
  @override
  State<WarmInteractionPage> createState() => _WarmInteractionPageState();
}

class _WarmInteractionPageState extends State<WarmInteractionPage> {
  bool connecting = false, starting = false;
  String error = '';
  VeniceWaveSession get s => widget.library.session;
  Future<void> start({bool real = false}) async {
    if (starting || s.active) return;
    if (!real && (!widget.developerAccess || !s.allowSimulation)) {
      setState(() => error = '请连接设备后启用实物输出。');
      return;
    }
    if (real && !widget.physical.canArm) {
      setState(() {
        connecting = true;
        error = '请先连接并选择设备。';
      });
      return;
    }
    final epoch = s.epoch;
    setState(() {
      starting = true;
      error = '';
    });
    try {
      if (!await widget.beforeStart()) {
        if (mounted) setState(() => error = '后台运行服务未启动，请检查权限后重试。');
        return;
      }
      if (!mounted || epoch != s.epoch) return;
      if (real) {
        widget.physical.caps.fillRange(0, 2, s.cap);
        await widget.physical.arm();
        if (!mounted || epoch != s.epoch) {
          await widget.physical.stop();
          return;
        }
      }
      s.grant(toDevice: real);
      if (real) setState(() => connecting = false);
      widget.library.markRecent(s.selected);
    } catch (_) {
      if (mounted) setState(() => error = '启用失败，请检查连接和后台权限。');
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  void limits() => showStrengthLimits(
    context,
    widget.library,
    widget.physical,
    developerAccess: widget.developerAccess,
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([s, widget.library, widget.physical]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, c) => Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '互动',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (widget.developerAccess)
                      WarmBadge(s.physical && s.active ? '设备模式' : '模拟模式'),
                    TextButton.icon(
                      onPressed: () => setState(() => connecting = true),
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('连接设备'),
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: c.maxHeight * .46),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: WarmControlCard(
                    library: widget.library,
                    physical: widget.physical,
                    onLimits: limits,
                    developerAccess: widget.developerAccess,
                  ),
                ),
              ),
              Expanded(
                child: WarmWaveLibraryPage(
                  library: widget.library,
                  onSelected: () {},
                  embedded: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (error.isNotEmpty)
                      Text(
                        error,
                        style: const TextStyle(fontSize: 11, color: warmRose),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: s.active
                              ? _RemainingTime(session: s)
                              : FilledButton.icon(
                                  key: const Key('venice_wave_grant'),
                                  onPressed:
                                      !widget.library.ready ||
                                          starting ||
                                          widget.physical.armed ||
                                          widget.physical.stopping ||
                                          widget.physical.unknown
                                      ? null
                                      : () {
                                          if (widget.developerAccess) {
                                            unawaited(start());
                                          } else if (widget.physical.canArm) {
                                            unawaited(start(real: true));
                                          } else {
                                            setState(() => connecting = true);
                                          }
                                        },
                                  icon: const Icon(Icons.play_arrow),
                                  label: Text(
                                    starting
                                        ? '准备中…'
                                        : widget.developerAccess
                                        ? '开始模拟'
                                        : widget.physical.canArm
                                        ? '启用实物输出'
                                        : '连接设备',
                                  ),
                                ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          key: const Key('interaction_stop'),
                          onPressed: widget.stop,
                          icon: const Icon(Icons.stop),
                          label: const Text('停止全部'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Keep the connection widget mounted when closed; disposing it closes its gateway.
          Visibility(
            visible: connecting,
            maintainState: true,
            child: Material(
              color: warmPaper,
              child: Column(
                children: [
                  ListTile(
                    title: const Text('连接设备'),
                    trailing: IconButton(
                      onPressed: () => setState(() => connecting = false),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          ConnectionPanel(
                            developerAccess: widget.developerAccess,
                            selectedDeviceId: widget.physical.gateway == null
                                ? null
                                : widget.physical.device?.id,
                            initialKind: 'dglab_v4',
                            onConnectionActivity: widget.onConnectionActivity,
                            disconnectSignal: widget.disconnectSignal,
                            beforeDisconnect: () async {
                              s.stop();
                              await widget.physical.release();
                            },
                            onBleSelected: (link) async {
                              s.stop();
                              await widget.physical.bindBle(link);
                            },
                            onDeviceSelected: (gateway, device) async {
                              s.stop();
                              await widget.physical.bind(gateway, device);
                            },
                          ),
                          const SizedBox(height: 16),
                          Text(widget.physical.status),
                          if (widget.physical.device == null)
                            const Text('先点击上方“选择此设备”，再启用实物输出。'),
                          if (s.active) const Text('当前会话运行中，请先停止全部，再启用实物输出。'),
                          const Text('实物输出目前仅支持内置波形；导入波形可预览与导出。'),
                          FilledButton(
                            onPressed:
                                starting ||
                                    !widget.physical.canArm ||
                                    s.active ||
                                    widget.physical.stopping ||
                                    widget.physical.unknown
                                ? null
                                : () => start(real: true),
                            child: const Text('启用实物输出'),
                          ),
                          const Text('不限总时长 · 启动先归零 · 手动停止、断连与故障停止继续生效。'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// Deadline is updated independently of waveform drawing and library scrolling.
class _RemainingTime extends StatefulWidget {
  const _RemainingTime({required this.session});
  final VeniceWaveSession session;
  @override
  State<_RemainingTime> createState() => _RemainingTimeState();
}

class _RemainingTimeState extends State<_RemainingTime> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    widget.session.physical ? '实物运行中 · 不限时' : '模拟运行中 · 不限时',
    style: const TextStyle(color: warmRose),
  );
}
