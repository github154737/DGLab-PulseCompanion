import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'coyote_ble.dart';

class CoyoteBlePanel extends StatefulWidget {
  const CoyoteBlePanel({
    super.key,
    required this.onSelected,
    this.beforeDisconnect,
    this.onConnectionActivity,
    this.disconnectSignal,
    this.createClient,
  });
  final Future<void> Function(CoyoteBle) onSelected;
  final Future<void> Function()? beforeDisconnect;
  final Future<bool> Function(bool)? onConnectionActivity;
  final Listenable? disconnectSignal;
  final CoyoteBle Function()? createClient;
  @override
  State<CoyoteBlePanel> createState() => _CoyoteBlePanelState();
}

class _CoyoteBlePanelState extends State<CoyoteBlePanel> {
  late final CoyoteBle ble;
  bool busy = false, bound = false, lease = false;
  String error = '';
  int generation = 0;
  @override
  void initState() {
    super.initState();
    ble = widget.createClient?.call() ?? CoyoteBle();
    ble.addListener(changed);
    widget.disconnectSignal?.addListener(externalStop);
  }

  void changed() {
    if (!mounted) return;
    if (ble.disconnected && lease && !busy) {
      bound = false;
      lease = false;
      unawaited(widget.onConnectionActivity?.call(false));
    }
    setState(() {});
  }

  void externalStop() => unawaited(disconnect());
  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } on PlatformException catch (e) {
      if (mounted) error = e.message ?? '蓝牙操作未完成';
    } catch (e) {
      if (mounted) error = '$e';
    } finally {
      if (mounted) {
        setState(() => busy = false);
        changed();
      }
    }
  }

  Future<void> scan() => run(() async {
    final stamp = ++generation;
    if (!await ble.permissions()) {
      error = '未授予蓝牙权限。请在系统应用设置中允许“附近的设备”；旧版 Android 需要位置权限。';
      return;
    }
    if (!mounted || stamp != generation) return;
    await ble.scan();
  });
  Future<void> connect(String id) => run(() async {
    final stamp = ++generation;
    if (!await ble.permissions() || !mounted || stamp != generation) return;
    if (!await (widget.onConnectionActivity?.call(true) ??
        Future.value(true))) {
      throw StateError('后台连接服务未启动，请保持前台重试');
    }
    lease = true;
    if (!mounted || stamp != generation) {
      lease = false;
      await widget.onConnectionActivity?.call(false);
      return;
    }
    await ble.connect(id);
  });
  Future<void> disconnect() async {
    generation++;
    if (mounted) {
      setState(() {
        bound = false;
        error = '';
      });
    }
    await widget.beforeDisconnect?.call();
    try {
      await ble.disconnect();
    } catch (_) {}
    // Native service also performs its own bounded stop before closing GATT.
    lease = false;
    await widget.onConnectionActivity?.call(false);
  }

  @override
  void dispose() {
    generation++;
    widget.disconnectSignal?.removeListener(externalStop);
    ble.removeListener(changed);
    ble.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('蓝牙直连 · 开发版', style: TextStyle(fontWeight: FontWeight.bold)),
      const Text('仅支持安卓与郊狼 3.0，无需打开 DG-LAB。请先断开其他 App 对设备的连接。本版尚未进行真实设备联调。'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            key: const Key('ble_scan'),
            onPressed: busy || !ble.disconnected || ble.scanning ? null : scan,
            icon: const Icon(Icons.bluetooth_searching),
            label: Text(ble.scanning ? '正在扫描…' : '扫描郊狼 3.0'),
          ),
          if (ble.scanning)
            TextButton(
              onPressed: () => run(ble.stopScan),
              child: const Text('停止扫描'),
            ),
          if (!ble.disconnected)
            OutlinedButton(onPressed: disconnect, child: const Text('断开蓝牙')),
        ],
      ),
      const SizedBox(height: 8),
      Text(ble.status),
      if (error.isNotEmpty)
        Text(
          error,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      if (ble.disconnected)
        for (final device in ble.devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bluetooth),
            title: Text(device['name'] as String),
            subtitle: Text(
              '标识尾号 ${(device['id'] as String).split(':').skip(4).join(':')} · 信号 ${device['rssi']} dBm',
            ),
            trailing: TextButton(
              onPressed: busy ? null : () => connect(device['id'] as String),
              child: const Text('连接'),
            ),
          ),
      if (!ble.disconnected) ...[
        Text(
          '设备报告强度：A ${ble.actualA ?? '—'} / B ${ble.actualB ?? '—'}（不是实测电流）',
        ),
        if (ble.state['battery'] != null)
          Text('连接时电量：${ble.state['battery']}%'),
        TextButton.icon(
          key: const Key('ble_select'),
          onPressed: !ble.ready || busy
              ? null
              : () => run(() async {
                  await widget.onSelected(ble);
                  if (mounted) setState(() => bound = true);
                }),
          icon: const Icon(Icons.link),
          label: Text(bound ? '已选择，输出需在下方启用' : '选择此设备'),
        ),
      ],
      const SizedBox(height: 8),
      const Text(
        '连接后先确认归零，启用后不限总时长，可随时停止。设备旋钮变化会撤销本次授权并请求归零。断开前会尝试归零并将设备软上限设为 0；返回官方 App 时请检查其上限设置。',
        style: TextStyle(fontSize: 12),
      ),
    ],
  );
}
