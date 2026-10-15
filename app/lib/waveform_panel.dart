import 'localization.dart';

import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'waveform_store.dart';

const envelopeExample =
    '{"format":"envelope_v1","id":"gentle_import","name":"我的渐变","channels":1,"frames":[{"duration_ms":500,"levels":[0.1,0]},{"duration_ms":500,"levels":[0.4,0]},{"duration_ms":500,"levels":[0.2,0]}]}';
const dglabExample =
    '{"format":"dglab_v3","id":"coyote_preview","name":"郊狼帧预览","a":["0A0A0A0A000A141E","0A0A0A0A1E140A00"],"b":[]}';

class WaveformPanel extends StatelessWidget {
  const WaveformPanel({
    super.key,
    required this.core,
    required this.state,
    required this.refresh,
    this.store,
    this.loading = false,
  });
  final CoreBridge core;
  final Map<String, dynamic> state;
  final VoidCallback refresh;
  final WaveformStore? store;
  final bool loading;
  bool get locked =>
      loading || ['authorized', 'playing', 'unknown'].contains(state['phase']);
  @override
  Widget build(BuildContext context) {
    final waves = state['waveforms'] as List? ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LText(
          loading
              ? '正在恢复本机波形库，请稍候…'
              : store == null
              ? '当前仅保留在会话内；可复制源文件留存'
              : '导入后保存在本机，重启后恢复。最多 24 个波形。',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const Key('import_waveform'),
              onPressed: locked
                  ? null
                  : () async {
                      await showDialog<void>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) =>
                            WaveformImportDialog(core: core, store: store),
                      );
                      refresh();
                    },
              icon: const Icon(Icons.file_open_outlined),
              label: const LText('导入 / 粘贴波形'),
            ),
            if (locked && !loading) const LText('编辑波形库前请停止当前会话'),
          ],
        ),
        for (final dynamic wave in waves)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: LText(wave['name']),
            subtitle: LText(
              '${wave['format']} · ${wave['channels']} 通道 · ${(wave['duration_ms'] as num) / 1000} 秒',
            ),
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: '模拟播放',
                  key: Key('wave_play_${wave['id']}'),
                  icon: const Icon(Icons.play_arrow),
                  onPressed:
                      state['phase'] == 'authorized' &&
                          (wave['channels'] as num) <=
                              (state['device']?['channels'] as num? ?? 0) &&
                          ((wave['format'] == 'dglab_v3') ==
                              (state['device']?['id'] == 'sim_dglab'))
                      ? () {
                          final r = core.call({
                            'op': 'play_waveform',
                            'waveform_id': wave['id'],
                          });
                          refresh();
                          if (r['ok'] != true) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: LText('未播放：${r['error']}')),
                            );
                          }
                        }
                      : null,
                ),
                IconButton(
                  tooltip: '移除波形',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: locked
                      ? null
                      : () async {
                          // Keep session controls inaccessible during the file/core transaction.
                          final navigator = Navigator.of(context);
                          unawaited(
                            showDialog<void>(
                              context: context,
                              barrierDismissible: false,
                              builder: (_) => const PopScope(
                                canPop: false,
                                child: AlertDialog(content: LText('正在移除波形…')),
                              ),
                            ),
                          );
                          try {
                            await store?.remove(wave['id']);
                            core.call({
                              'op': 'remove_waveform',
                              'waveform_id': wave['id'],
                            });
                            refresh();
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: LText('移除文件失败，已保留波形')),
                              );
                            }
                          } finally {
                            navigator.pop();
                          }
                        },
                ),
              ],
            ),
          ),
        if (waves.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: LText(
              '支持 envelope_v1 JSON 与 dglab_v3 帧封装。收到你的实际导出文件后再补对应解析器。',
            ),
          ),
      ],
    );
  }
}

class WaveformImportDialog extends StatefulWidget {
  const WaveformImportDialog({super.key, required this.core, this.store});
  final CoreBridge core;
  final WaveformStore? store;
  @override
  State<WaveformImportDialog> createState() => _WaveformImportDialogState();
}

class _WaveformImportDialogState extends State<WaveformImportDialog> {
  final source = TextEditingController();
  final scroll = ScrollController();
  final identity = TextEditingController(text: 'coyote_import');
  bool rawDglab = false, busy = false;
  Map<String, dynamic>? preview;
  String? error;
  @override
  void dispose() {
    source.dispose();
    scroll.dispose();
    identity.dispose();
    super.dispose();
  }

  void validate() {
    try {
      var raw = source.text.trim();
      if (utf8.encode(raw).length > 32768) {
        throw const FormatException('文件不能超过 32 KiB');
      }
      if (rawDglab) {
        final blocks = jsonDecode(raw);
        if (blocks is! List || blocks.any((v) => v is! String)) {
          throw const FormatException('请粘贴十六进制帧字符串数组');
        }
        raw = jsonEncode({
          'format': 'dglab_v3',
          'id': identity.text.trim(),
          'name': identity.text.trim(),
          'a': blocks,
          'b': [],
        });
      }
      final r = widget.core.call({'op': 'validate_waveform', 'source': raw});
      if (r['ok'] != true) throw FormatException(r['error'].toString());
      setState(() {
        preview = Map<String, dynamic>.from(r['result']);
        error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          unawaited(
            scroll.animateTo(
              scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            ),
          );
        }
      });
    } catch (e) {
      setState(() {
        preview = null;
        error = '无法导入：$e';
      });
    }
  }

  Future<void> chooseFile() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: '波形 JSON', extensions: ['json', 'txt', 'dg']),
        ],
      );
      if (file == null) return;
      if (await file.length() > 32768) {
        throw const FormatException('文件不能超过 32 KiB');
      }
      final text = await file.readAsString();
      if (!mounted) return;
      setState(() {
        source.text = text;
        preview = null;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '读取失败：$e');
    }
  }

  Future<void> save() async {
    if (preview == null || busy) return;
    setState(() => busy = true);
    final canonical = Map<String, dynamic>.from(preview!['canonical']);
    var imported = false;
    try {
      final r = widget.core.call({
        'op': 'import_waveform',
        'source': jsonEncode(canonical),
      });
      if (r['ok'] != true) throw FormatException(r['error'].toString());
      imported = true;
      await widget.store?.save(canonical);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (imported) {
        widget.core.call({
          'op': 'remove_waveform',
          'waveform_id': canonical['id'],
        });
      }
      if (mounted) {
        setState(() {
          error = '保存失败：$e';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const LText('导入波形 · 先校验再保存'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          controller: scroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  TextButton.icon(
                    onPressed: busy ? null : chooseFile,
                    icon: const Icon(Icons.folder_open),
                    label: const LText('选择文件'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () {
                            setState(() {
                              source.text = envelopeExample;
                              rawDglab = false;
                              preview = null;
                            });
                          },
                    child: const LText('通用示例'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () {
                            setState(() {
                              source.text = dglabExample;
                              rawDglab = false;
                              preview = null;
                            });
                          },
                    child: const LText('郊狼示例'),
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const LText(
                  '输入是郊狼 V3 原始帧数组',
                  style: TextStyle(fontSize: 13),
                ),
                value: rawDglab,
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        rawDglab = v!;
                        preview = null;
                      }),
              ),
              if (rawDglab)
                TextField(
                  controller: identity,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    label: LText('波形 ID（英文、数字、_、-）'),
                  ),
                  onChanged: (_) => setState(() => preview = null),
                ),
              TextField(
                key: const Key('wave_source'),
                controller: source,
                enabled: !busy,
                minLines: 5,
                maxLines: 8,
                maxLength: 32768,
                decoration: const InputDecoration(hint: LText('粘贴 JSON，或选择文件')),
                onChanged: (_) => setState(() => preview = null),
              ),
              const LText(
                '郊狼频率参数与通道强度分别保留。预览只显示相对幅度，不向实体设备发送。',
                style: TextStyle(fontSize: 12),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: LText(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              if (preview != null) ...[
                const SizedBox(height: 12),
                LText(
                  '${preview!['waveform']['name']} · ${(preview!['waveform']['duration_ms'] as num) / 1000} 秒',
                ),
                SizedBox(
                  height: 90,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: WaveformPreviewPainter(
                      preview!['samples'] as List,
                      preview!['waveform']['duration_ms'] as num,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const LText('取消'),
        ),
        OutlinedButton(
          key: const Key('validate_waveform'),
          onPressed: busy ? null : validate,
          child: const LText('校验预览'),
        ),
        FilledButton(
          key: const Key('save_waveform'),
          onPressed: preview == null || busy ? null : save,
          child: const LText('导入'),
        ),
      ],
    ),
  );
}

class WaveformPreviewPainter extends CustomPainter {
  WaveformPreviewPainter(this.samples, this.duration);
  final List samples;
  final num duration;
  @override
  void paint(Canvas canvas, Size size) {
    for (var ch = 0; ch < 2; ch++) {
      final path = Path();
      var first = true;
      for (final dynamic s in samples) {
        final x = (s['at_ms'] as num) / duration * size.width,
            y = size.height - (s['values'][ch] as num) * size.height;
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
          ..color = (ch == 0 ? const Color(0xFF177E70) : Colors.orange)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPreviewPainter old) =>
      old.samples != samples;
}
