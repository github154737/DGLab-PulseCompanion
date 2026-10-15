import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'connection_panel.dart';
import 'physical_output.dart';
import 'pulse_library.dart';
import 'venice_wave_session.dart';

class VeniceWavePanel extends StatefulWidget {
  const VeniceWavePanel({
    super.key,
    required this.session,
    required this.physical,
  });
  final VeniceWaveSession session;
  final PhysicalOutput physical;
  @override
  State<VeniceWavePanel> createState() => _VeniceWavePanelState();
}

class _VeniceWavePanelState extends State<VeniceWavePanel>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  String query = '', message = '正在读取波形库…';
  bool loading = true;
  File? savedLibrary;
  Timer? refresh;
  VeniceWaveSession get s => widget.session;
  @override
  void initState() {
    super.initState();
    unawaited(restore());
    refresh = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && s.active) setState(() {});
    });
  }

  Future<void> restore() async {
    try {
      final bytes = await rootBundle.load('assets/user-waveforms.zip');
      final imported = importPulseFiles(
        'library.zip',
        bytes.buffer.asUint8List(),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      s.add(imported);
      message = s.receipt;
      final dir = await getApplicationSupportDirectory();
      savedLibrary = File('${dir.path}/venice-pulse-library.json');
      if (await savedLibrary!.exists() &&
          await savedLibrary!.length() <= 24 * 1024 * 1024) {
        final rows = jsonDecode(await savedLibrary!.readAsString()) as List;
        if (rows.length > 1000) throw const FormatException();
        for (final row in rows) {
          if (!mounted) return;
          s.add(
            importPulseFiles(
              row['name'] as String,
              base64Decode(row['bytes'] as String),
            ),
          );
        }
      }
    } catch (_) {
      message += ' · 自定义库恢复不可用，可重新导入文件';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> importFiles() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: '郊狼波形',
            extensions: const ['pulse', 'zip'],
            mimeTypes: Platform.isAndroid ? const ['*/*'] : null,
          ),
        ],
      );
      if (file == null || !mounted) return;
      setState(() => loading = true);
      if (await file.length() > 8 * 1024 * 1024) throw const FormatException();
      final result = importPulseFiles(file.name, await file.readAsBytes());
      if (!mounted) return;
      s.add(result);
      message = s.receipt;
      final directory = await getApplicationSupportDirectory();
      savedLibrary = File('${directory.path}/venice-pulse-library.json');
      await directory.create(recursive: true);
      final pending = File('${savedLibrary!.path}.pending');
      await pending.writeAsString(
        jsonEncode(
          s.waves
              .where((w) => !w.deviceReady)
              .map(
                (w) => {
                  'name': '${w.name}.pulse',
                  'bytes': base64Encode(w.bytes),
                },
              )
              .toList(),
        ),
        flush: true,
      );
      if (await savedLibrary!.exists()) await savedLibrary!.delete();
      await pending.rename(savedLibrary!.path);
      if (result.errors.isNotEmpty) {
        message += '；未解析：${result.errors.take(3).join('、')}';
      }
    } catch (_) {
      message = '导入或保存失败，已加载的波形仍可在本轮使用';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> exportWave(PulseWave wave) async {
    try {
      final name =
          '${wave.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.pulse';
      if (Platform.isAndroid) {
        final saved = await const MethodChannel('aihaptics/files')
            .invokeMethod<bool>('export_pulse', {
              'name': name,
              'bytes': wave.bytes,
            });
        if (saved == true && mounted) {
          setState(() => message = '已原样导出 ${wave.name}，可交给 DGLAB APP 导入');
        }
        return;
      }
      final location = await getSaveLocation(suggestedName: name);
      if (location != null) {
        await XFile.fromData(wave.bytes).saveTo(location.path);
        if (mounted) {
          setState(() => message = '已原样导出 ${wave.name}，可交给 DGLAB APP 导入');
        }
      }
    } catch (_) {
      if (mounted) setState(() => message = '导出失败，请选择可写入的位置');
    }
  }

  @override
  void dispose() {
    refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s, widget.physical]),
      builder: (context, _) => ExpansionTile(
        key: const Key('venice_waves'),
        maintainState: true,
        title: const Text('波形与 A/B 强度'),
        subtitle: Text(s.receipt),
        childrenPadding: const EdgeInsets.all(12),
        children: [
          Text(
            '当前：${s.physical ? '实物输出' : '模拟预览'} · ${s.active ? "不限时" : "未启动"}',
          ),
          Text(
            'A ${s.strength[0]} / B ${s.strength[1]} · 上限 ${s.cap} · ${s.wave.name}',
          ),
          SizedBox(
            height: 100,
            width: double.infinity,
            child: CustomPaint(
              painter: _PulsePainter(
                s.wave.levels,
                s.active ? s.tickIndex : 0,
                s.cap == 0 ? 0 : s.strength[0] / s.cap,
                s.cap == 0 ? 0 : s.strength[1] / s.cap,
              ),
            ),
          ),
          const Text('导入波形显示形状预览，横轴不是已验证的真实时长；原生格式转换完成前不向实物发送。'),
          const Text('灰线：原始形状；青线 A / 橙线 B：当前上限内的目标比例，非实测电流。'),
          Slider(
            value: s.cap.toDouble(),
            min: 0,
            max: 50,
            divisions: 50,
            label: '${s.cap}',
            onChanged: s.active
                ? null
                : (v) => setState(() => s.setCap(v.round())),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const Key('venice_wave_grant'),
                onPressed:
                    loading ||
                        s.active ||
                        widget.physical.armed ||
                        widget.physical.stopping ||
                        widget.physical.unknown
                    ? null
                    : () => s.grant(),
                child: const Text('开始 AI 模拟'),
              ),
              FilledButton.tonal(
                onPressed: () {
                  s.stop();
                  unawaited(widget.physical.stop());
                },
                child: const Text('立即停止并归零'),
              ),
              OutlinedButton(
                onPressed: loading || s.active ? null : importFiles,
                child: const Text('导入 .pulse / ZIP'),
              ),
            ],
          ),
          for (var channel = 0; channel < 2; channel++)
            Row(
              children: [
                Text('${channel == 0 ? 'A' : 'B'} 强度'),
                for (final step in [-s.manualStep, s.manualStep])
                  TextButton(
                    onPressed: !s.active
                        ? null
                        : () {
                            s.invalidate('manual_strength');
                            final next = List<int>.of(s.strength);
                            next[channel] = (next[channel] + step).clamp(
                              0,
                              s.cap,
                            );
                            s.apply({
                              'action': 'set',
                              'a': next[0],
                              'b': next[1],
                              'waveform_id': s.selected,
                            }, s.epoch);
                          },
                    child: Text(step > 0 ? '+$step' : '−${-step}'),
                  ),
              ],
            ),
          Text(message),
          Text('波形库 ${s.waves.length} 个 · AI 候选 ${s.candidates.length}/24'),
          TextField(
            decoration: const InputDecoration(labelText: '搜索波形名称'),
            onChanged: (v) => setState(() => query = v),
          ),
          SizedBox(
            height: 220,
            child: ListView(
              children: [
                for (final w in s.waves.where((w) => w.name.contains(query)))
                  ListTile(
                    dense: true,
                    leading: Checkbox(
                      value: s.candidates.contains(w.id),
                      onChanged: s.active
                          ? null
                          : (v) => setState(() {
                              if (v == true && s.candidates.length < 24) {
                                s.candidates.add(w.id);
                              }
                              if (v != true && w.id != s.selected) {
                                s.candidates.remove(w.id);
                              }
                            }),
                    ),
                    title: Text(w.name),
                    subtitle: Text(
                      w.deviceReady ? '内置协议帧 · 可用于实物' : '原生文件 · 可预览和原样导出',
                    ),
                    selected: s.selected == w.id,
                    onTap: () {
                      if (s.physical && s.active && !w.deviceReady) return;
                      if (!s.candidates.contains(w.id) &&
                          s.candidates.length >= 24) {
                        return;
                      }
                      s.candidates.add(w.id);
                      s.invalidate('manual_waveform');
                      if (s.active) {
                        s.apply({
                          'action': 'set',
                          'a': s.strength[0],
                          'b': s.strength[1],
                          'waveform_id': w.id,
                        }, s.epoch);
                      } else {
                        setState(() => s.selected = w.id);
                      }
                    },
                    trailing: !w.deviceReady
                        ? IconButton(
                            tooltip: '原样导出 .pulse',
                            onPressed: () => exportWave(w),
                            icon: const Icon(Icons.download),
                          )
                        : null,
                  ),
              ],
            ),
          ),
          ExpansionTile(
            title: const Text('连接郊狼 3.0（DGLAB APP 中转）'),
            children: [
              ConnectionPanel(
                beforeDisconnect: () async {
                  s.stop();
                  await widget.physical.stop();
                },
                onDeviceSelected: (gateway, device) async {
                  s.stop();
                  await widget.physical.bind(gateway, device);
                },
              ),
              Text(widget.physical.status),
              FilledButton(
                onPressed:
                    !widget.physical.canArm ||
                        s.active ||
                        widget.physical.stopping ||
                        widget.physical.unknown
                    ? null
                    : () async {
                        final stamp = s.epoch;
                        try {
                          widget.physical.caps.fillRange(0, 2, s.cap);
                          await widget.physical.arm();
                          if (!mounted || stamp != s.epoch) {
                            await widget.physical.stop();
                            return;
                          }
                          s.grant(toDevice: true);
                        } catch (_) {
                          if (mounted) {
                            setState(() => message = '实物启用失败，请检查配对状态');
                          }
                        }
                      },
                child: const Text('启用实物输出（仅内置波形）'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter(this.levels, this.tick, this.a, this.b);
  final List<double> levels;
  final int tick;
  final double a, b;
  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final path = Path();
    final count = levels.length.clamp(2, 500);
    for (var i = 0; i < count; i++) {
      final index = (i * (levels.length - 1) / (count - 1)).floor();
      final x = i * size.width / (count - 1),
          y = (1 - levels[index]) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.grey
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    for (var channel = 0; channel < 2; channel++) {
      canvas.save();
      final gain = channel == 0 ? a : b;
      canvas.translate(0, size.height * (1 - gain));
      canvas.scale(1, gain == 0 ? 0.00001 : gain);
      canvas.drawPath(
        path,
        Paint()
          ..color = channel == 0 ? Colors.teal : Colors.orange
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
      canvas.restore();
    }
    final cursor = (tick % levels.length) / levels.length * size.width;
    canvas.drawLine(
      Offset(cursor, 0),
      Offset(cursor, size.height),
      Paint()..color = Colors.orange,
    );
  }

  @override
  bool shouldRepaint(_PulsePainter old) =>
      old.levels != levels || old.tick != tick || old.a != a || old.b != b;
}
