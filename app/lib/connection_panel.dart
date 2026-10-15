import 'localization.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'device_gateway.dart';
import 'coyote_ble.dart';
import 'coyote_ble_panel.dart';
import 'dglab_pairing.dart';
import 'network_diagnostics.dart';

class ConnectionPanel extends StatefulWidget {
  const ConnectionPanel({
    super.key,
    this.createGateway,
    this.onDeviceSelected,
    this.beforeDisconnect,
    this.initialKind = 'intiface',
    this.onConnectionActivity,
    this.disconnectSignal,
    this.openPairingLink,
    this.onBleSelected,
    this.selectedDeviceId,
    this.developerAccess = true,
  });
  final DeviceGateway Function(String kind)? createGateway;
  final Future<void> Function(DglabV4Gateway gateway, RemoteDevice device)?
  onDeviceSelected;
  final Future<void> Function()? beforeDisconnect;
  final String initialKind;
  final Future<bool> Function(bool active)? onConnectionActivity;
  final Listenable? disconnectSignal;
  final Future<bool> Function(Uri uri)? openPairingLink;
  final Future<void> Function(CoyoteBle)? onBleSelected;
  final String? selectedDeviceId;
  final bool developerAccess;
  @override
  State<ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends State<ConnectionPanel>
    with WidgetsBindingObserver {
  final trace = NetworkTrace('设备配对');
  String? selecting;
  final endpoint = TextEditingController(text: 'ws://127.0.0.1:12345');
  String kind = 'intiface', status = '尚未连接';
  DeviceGateway? gateway;
  StreamSubscription<void>? subscription;
  bool busy = false;
  bool openingPairing = false;
  bool bleActive = false;
  String handoffStatus = '';
  int generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.disconnectSignal?.addListener(requestDisconnect);
    if (!widget.developerAccess || widget.initialKind == 'dglab_v4') {
      kind = 'dglab_v4';
      endpoint.text = 'wss://trex.dungeon-lab.cn/v4';
    }
  }

  void requestDisconnect() => unawaited(disconnect());

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && gateway != null) {
      trace.mark('返回前台 · 刷新设备状态');
      unawaited(readDevices());
    }
  }

  @override
  void didUpdateWidget(covariant ConnectionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.disconnectSignal != widget.disconnectSignal) {
      oldWidget.disconnectSignal?.removeListener(requestDisconnect);
      widget.disconnectSignal?.addListener(requestDisconnect);
    }
    if (oldWidget.developerAccess && !widget.developerAccess) {
      if (kind != 'dglab_v4') unawaited(disconnect());
      kind = 'dglab_v4';
      endpoint.text = 'wss://trex.dungeon-lab.cn/v4';
    }
  }

  bool owns(DeviceGateway value, int stamp) =>
      mounted && generation == stamp && identical(gateway, value);
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    generation++;
    widget.disconnectSignal?.removeListener(requestDisconnect);
    unawaited(subscription?.cancel());
    unawaited(gateway?.close());
    endpoint.dispose();
    super.dispose();
  }

  Future<void> disconnect() async {
    final old = gateway;
    final oldSubscription = subscription;
    generation++;
    setState(() {
      gateway = null;
      subscription = null;
      busy = false;
      status = '已断开';
      handoffStatus = '';
    });
    await widget.beforeDisconnect?.call();
    await oldSubscription?.cancel();
    await old?.close();
    // A replacement connection owns the background lease from this point.
    if (mounted && gateway == null) {
      await widget.onConnectionActivity?.call(false);
    }
  }

  Future<void> connect() async {
    if (busy || gateway != null) return;
    if (!widget.developerAccess) {
      kind = 'dglab_v4';
      endpoint.text = 'wss://trex.dungeon-lab.cn/v4';
    }
    final stamp = ++generation;
    setState(() => busy = true);
    final next =
        widget.createGateway?.call(kind) ??
        (kind == 'intiface' ? IntifaceGateway() : DglabV4Gateway());
    gateway = next;
    subscription = next.changes.listen(
      (_) {
        if (owns(next, stamp)) {
          trace.mark(
            '设备更新 · 总数 ${next.devices.length} · 已连接 ${next.devices.where((d) => d.connectedCoyote).length}',
          );
          setState(() => status = next.status);
        }
      },
      onDone: () {
        if (owns(next, stamp)) {
          setState(() {
            status = next.status;
            gateway = null;
            subscription = null;
            busy = false;
            handoffStatus = '';
          });
          unawaited(widget.onConnectionActivity?.call(false));
        }
      },
    );
    try {
      final ready = await widget.onConnectionActivity?.call(true) ?? true;
      if (!owns(next, stamp)) return;
      if (!ready) throw StateError('后台连接服务未启动，请保持前台并重试');
      await next.connect(Uri.parse(endpoint.text.trim()));
      if (owns(next, stamp)) {
        setState(() => status = next.status);
      }
    } catch (e) {
      if (owns(next, stamp)) {
        await disconnect();
        if (mounted && gateway == null) {
          setState(() => status = '连接未成功：$e');
        }
      }
    } finally {
      if (owns(next, stamp)) setState(() => busy = false);
    }
  }

  Future<void> openPairing(Uri uri) async {
    if (openingPairing || gateway?.pairingUri != uri) return;
    final stamp = generation;
    setState(() {
      openingPairing = true;
      handoffStatus = '';
    });
    var opened = false;
    try {
      opened =
          await (widget.openPairingLink?.call(dglabAppPairingUri(uri)) ??
              launchUrl(
                dglabAppPairingUri(uri),
                mode: LaunchMode.externalApplication,
              ));
    } catch (_) {
      opened = false;
    }
    if (mounted) {
      setState(() {
        openingPairing = false;
        if (generation == stamp && gateway?.pairingUri == uri) {
          handoffStatus = opened
              ? '已直接打开 DG-LAB；完成 Socket 配对后返回并选择设备。打开页面不代表配对成功。'
              : '未能打开配对页面。请确认已安装 DG-LAB 4，或使用二维码扫码配对。';
          trace.mark('直接唤起 DG-LAB · 成功=$opened');
        }
      });
    }
  }

  Future<void> selectDevice(RemoteDevice device) async {
    final current = gateway;
    if (current is! DglabV4Gateway ||
        selecting != null ||
        !device.connectedCoyote ||
        widget.onDeviceSelected == null) {
      return;
    }
    final stamp = generation;
    setState(() => selecting = device.id);
    trace.mark('用户选择设备 · 蓝牙已连接=true');
    try {
      await widget.onDeviceSelected!(current, device);
      if (owns(current, stamp)) {
        setState(() => status = '设备已选择，请点击下方“启用实物输出”；启动会先确认 A/B 归零。');
        trace.mark('绑定完成 · 等待用户启用输出');
      }
    } catch (_) {
      if (owns(current, stamp)) {
        setState(() => status = '设备选择失败，请检查连接或下方停止状态后重试');
        trace.mark('设备绑定失败');
      }
    } finally {
      if (mounted) setState(() => selecting = null);
    }
  }

  Future<void> readDevices({bool scan = false}) async {
    final current = gateway;
    if (current == null || busy) return;
    final stamp = generation;
    setState(() => busy = true);
    try {
      if (scan && current is IntifaceGateway) {
        await current.scan();
      } else {
        await current.refresh();
      }
    } catch (_) {
      if (owns(current, stamp)) setState(() => status = '读取失败，请检查服务后重新连接');
    } finally {
      if (owns(current, stamp)) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const LText(
        '设备发现不会开启输出。选择郊狼 3.0 后，在实物输出面板显式启用。\nDiscovery does not enable output. Select Coyote 3.0, then enable it in Physical output.',
        style: TextStyle(fontSize: 12),
      ),
      const SizedBox(height: 12),
      if (widget.developerAccess)
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: kind,
          decoration: const InputDecoration(label: LText('连接方式')),
          items: [
            const DropdownMenuItem(
              value: 'intiface',
              child: LText('Intiface / 多品牌'),
            ),
            const DropdownMenuItem(
              value: 'dglab_v4',
              child: LText('郊狼 / DG-LAB 4', overflow: TextOverflow.ellipsis),
            ),
            if (Platform.isAndroid && widget.onBleSelected != null)
              const DropdownMenuItem(
                value: 'coyote_ble',
                child: LText('郊狼 3.0 / 蓝牙直连（开发版）'),
              ),
          ],
          onChanged: gateway != null || busy || bleActive
              ? null
              : (v) => setState(() {
                  kind = v!;
                  endpoint.text = kind == 'intiface'
                      ? 'ws://127.0.0.1:12345'
                      : 'wss://trex.dungeon-lab.cn/v4';
                }),
        ),
      const SizedBox(height: 10),
      if (widget.developerAccess && kind == 'coyote_ble')
        CoyoteBlePanel(
          onSelected: widget.onBleSelected!,
          beforeDisconnect: widget.beforeDisconnect,
          disconnectSignal: widget.disconnectSignal,
          onConnectionActivity: (active) async {
            final ok = await widget.onConnectionActivity?.call(active) ?? true;
            if (mounted) setState(() => bleActive = active && ok);
            return ok;
          },
        )
      else ...[
        if (widget.developerAccess)
          TextField(
            key: const Key('gateway_endpoint'),
            controller: endpoint,
            enabled: gateway == null && !busy,
            decoration: const InputDecoration(label: LText('服务地址')),
          ),
        const SizedBox(height: 8),
        LText(
          kind == 'intiface'
              ? '先启动同一设备上的 Intiface Central 服务，再连接。扫描需单独点击；支持情况以返回的能力为准。'
              : '同一台手机即可：连接服务 → 打开 DG-LAB 配对 → 返回选择蓝牙设备 → 显式启用输出。DG-LAB 4 负责蓝牙连接；本页不会自动开启输出。',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: busy || gateway != null ? null : connect,
              child: const LText('连接服务'),
            ),
            if (gateway != null)
              TextButton(onPressed: disconnect, child: const LText('断开服务')),
            if (gateway != null)
              OutlinedButton(
                onPressed: busy ? null : () => readDevices(),
                child: const LText('刷新设备'),
              ),
            if (gateway is IntifaceGateway)
              OutlinedButton(
                onPressed: busy ? null : () => readDevices(scan: true),
                child: const LText('扫描 5 秒'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        LText(
          !widget.developerAccess && status.startsWith('连接未成功：')
              ? '连接未成功，请检查网络后重试。'
              : status,
          style: const TextStyle(fontSize: 12),
        ),
        if (gateway?.pairingUri case final uri?) ...[
          const SizedBox(height: 8),
          const LText(
            'APP 配对链接',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          FilledButton.icon(
            key: const Key('open_dglab_pairing'),
            onPressed: openingPairing ? null : () => openPairing(uri),
            icon: const Icon(Icons.open_in_new),
            label: const LText('在本机打开 DG-LAB 配对'),
          ),
          const LText(
            '直接唤起 DG-LAB，不经过浏览器。若提示“当前业务尚未完成”，请先关闭 DG-LAB 内的失败弹窗、断开旧 Socket 连接，再返回这里重试。配对期间请勿断开本页服务。',
            style: TextStyle(fontSize: 12),
          ),
          if (handoffStatus.isNotEmpty) LText(handoffStatus),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: uri.toString()));
              if (mounted) {
                setState(() => handoffStatus = '已复制，可粘贴到手机浏览器打开。链接仅在本次连接期间有效。');
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const LText('复制配对链接'),
          ),
          TextButton.icon(
            key: const Key('copy_dglab_socket'),
            onPressed: () async {
              final socket = uri.queryParameters['url'];
              if (socket == null) return;
              await Clipboard.setData(ClipboardData(text: socket));
              if (mounted) {
                setState(
                  () => handoffStatus = '已复制 Socket 地址。在 DG-LAB 的 Socket 控制页断开旧连接，将地址完整粘贴到服务器地址栏，再连接服务器。不要把 HTTPS 配对链接填进服务器地址栏。',
                );
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const LText('复制 Socket 地址（手动配对）'),
          ),
          ExpansionTile(
            title: const LText('其他手机扫码 / 查看配对链接'),
            children: [
              Center(
                child: QrImageView(
                  data: uri.toString(),
                  size: 216,
                  backgroundColor: Colors.white,
                ),
              ),
              SelectableText(
                uri.toString(),
                style: const TextStyle(fontSize: 11),
              ),
              const LText('二维码仅在本次连接期间有效，重新连接后请使用新链接。'),
            ],
          ),
        ],
        for (final d in gateway?.devices ?? <RemoteDevice>[])
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.sensors),
            title: LText(d.name),
            subtitle: LText(
              d.kind == 'COYOTE_030'
                  ? (d.connectedCoyote
                        ? (widget.selectedDeviceId == d.id
                              ? '已选择 · 请在下方启用实物输出'
                              : '蓝牙已连接 · 下一步：选择此设备')
                        : '蓝牙未连接或状态未确认，请在 DG-LAB 中连接')
                  : widget.developerAccess
                  ? '${d.kind} · ${d.channels} 个已识别通道'
                  : '当前设备暂不支持输出',
            ),
            trailing:
                gateway is DglabV4Gateway &&
                    d.kind == 'COYOTE_030' &&
                    widget.onDeviceSelected != null
                ? FilledButton.tonal(
                    key: ValueKey('select_device_${d.id}'),
                    onPressed:
                        !d.connectedCoyote ||
                            selecting != null ||
                            widget.selectedDeviceId == d.id
                        ? null
                        : () => selectDevice(d),
                    child: Text(
                      selecting == d.id
                          ? '选择中…'
                          : widget.selectedDeviceId == d.id
                          ? '已选择'
                          : '选择此设备',
                    ),
                  )
                : null,
            onTap: d.connectedCoyote && widget.selectedDeviceId != d.id
                ? () => selectDevice(d)
                : null,
          ),
      ],
    ],
  );
}
