import 'control_slider.dart';
import 'localization.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef ControlAction = Map<String, dynamic> Function(
  Map<String, dynamic> request,
);

class ChannelConsole extends StatefulWidget {
  const ChannelConsole({
    super.key,
    required this.state,
    required this.act,
    this.notes = const ['A', 'B'],
    this.onNoteSaved,
  });
  final Map<String, dynamic> state;
  final ControlAction act;
  final List<String> notes;
  final Future<void> Function(int channel, String note)? onNoteSaved;
  @override
  State<ChannelConsole> createState() => _ChannelConsoleState();
}

class _ChannelConsoleState extends State<ChannelConsole> {
  final patterns = ['lab_breathe', 'lab_tide'];
  final strengths = <int, double>{}, limits = <int, double>{};
  final names = [
    TextEditingController(text: 'A'),
    TextEditingController(text: 'B'),
  ];
  double duration = 5;
  bool repeat = true;
  String receipt = '';
  @override
  void initState() {
    super.initState();
    for (var i = 0; i < 2; i++) {
      names[i].text = widget.notes[i];
    }
  }

  bool get authorized =>
      ['authorized', 'playing'].contains(widget.state['phase']);
  void action(int channel, Map<String, dynamic> command) {
    final result = widget.act({
      'op': 'channel_actions',
      'actions': [
        {'channel': channel, 'command': command},
      ],
    });
    setState(
      () => receipt = result['ok'] == true
          ? '${channel == 0 ? 'A' : 'B'} · 动作已通过核心校验（仿真）'
          : '未执行：${result['error']}',
    );
  }

  @override
  void dispose() {
    for (final name in names) {
      name.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channels = widget.state['channels'] as List? ?? [];
    final catalog = widget.state['pattern_catalog'] as List? ?? [];
    final count = (widget.state['device']?['channels'] as num? ?? 2).toInt();
    return ExpansionTile(
      title: const LText('A/B 独立控制台'),
      subtitle: const LText('单通道强度、上限、波形与临时动作'),
      childrenPadding: const EdgeInsets.all(12),
      children: [
        const LText('通道强度与上限均为相对比例，继续受本次总上限约束。单次手动增加最多 20%，AI 增加最多 10%。'),
        for (
          var index = 0;
          index < count && index < channels.length;
          index++
        ) ...[
          const Divider(),
          TextField(
            controller: names[index],
            onSubmitted: (text) async {
              try {
                await widget.onNoteSaved?.call(index, text);
              } catch (_) {
                if (mounted) setState(() => receipt = '备注未保存 / Note not saved');
              }
            },
            maxLength: 40,
            decoration: InputDecoration(
              label: LText('${index == 0 ? 'A' : 'B'} 通道名称 / 配件备注'),
              counterText: '',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const LText('启用通道'),
            value: channels[index]['enabled'] == true,
            onChanged: widget.state['phase'] == 'unknown'
                ? null
                : (v) {
                    final result = widget.act({
                      'op': 'configure_channel',
                      'channel': index,
                      'enabled': v,
                      'limit': channels[index]['limit'],
                    });
                    if (result['ok'] != true) {
                      setState(() => receipt = '未执行：${result['error']}');
                    }
                  },
          ),
          LText(
            '通道上限：${((limits[index] ?? (channels[index]['limit'] as num).toDouble()) * 100).round()}%',
          ),
          ControlSlider(
            value:
                limits[index] ?? (channels[index]['limit'] as num).toDouble(),
            divisions: 20,
            onChanged: widget.state['phase'] == 'unknown'
                ? null
                : (v) => setState(() => limits[index] = v),
            onChangeEnd: (v) {
              widget.act({
                'op': 'configure_channel',
                'channel': index,
                'enabled': channels[index]['enabled'],
                'limit': v,
              });
              setState(() => limits.remove(index));
            },
          ),
          LText(
            '通道相对强度：${((strengths[index] ?? (channels[index]['target'] as num).toDouble()) * 100).round()}%',
          ),
          ControlSlider(
            key: Key('channel_strength_$index'),
            value:
                strengths[index] ??
                (channels[index]['target'] as num).toDouble(),
            divisions: 20,
            onChanged: authorized && channels[index]['enabled'] == true
                ? (v) => setState(() => strengths[index] = v)
                : null,
            onChangeEnd: (v) {
              action(index, {'kind': 'strength', 'value': v});
              setState(() => strengths.remove(index));
            },
          ),
          Wrap(
            spacing: 6,
            children: [
              OutlinedButton(
                onPressed: authorized
                    ? () => action(index, {'kind': 'adjust', 'delta': -0.1})
                    : null,
                child: const LText('−10%'),
              ),
              OutlinedButton(
                onPressed: authorized
                    ? () => action(index, {'kind': 'adjust', 'delta': 0.1})
                    : null,
                child: const LText('+10%'),
              ),
              OutlinedButton(
                onPressed: authorized
                    ? () => action(index, {
                        'kind': 'strength',
                        'value': channels[index]['target'],
                        'duration_ms': (duration * 1000).round(),
                      })
                    : null,
                child: const LText('临时保持'),
              ),
              TextButton(
                key: Key('clear_channel_$index'),
                onPressed: authorized
                    ? () => action(index, {'kind': 'clear'})
                    : null,
                child: const LText('清除此通道'),
              ),
            ],
          ),
          if (catalog.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: patterns[index],
              isExpanded: true,
              decoration: const InputDecoration(label: LText('独立波形')),
              items: [
                for (final p in catalog)
                  DropdownMenuItem(
                    value: p['id'] as String,
                    child: LText(
                      p[LanguageScope.of(context) == 'en' ? 'name_en' : 'name']
                          as String,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => patterns[index] = v!),
            ),
          OutlinedButton.icon(
            onPressed: authorized
                ? () => action(index, {
                    'kind': 'pattern',
                    'preset_id': patterns[index],
                    'duration_ms': (duration * 1000).round(),
                    'repeat': repeat,
                  })
                : null,
            icon: const Icon(Icons.play_arrow),
            label: LText('播放 ${index == 0 ? 'A' : 'B'} 通道'),
          ),
        ],
        LText('动作时长：${duration.round()} 秒'),
        ControlSlider(
          value: duration,
          min: 1,
          max: 20,
          divisions: 19,
          onChanged: (v) => setState(() => duration = v),
        ),
        SwitchListTile(
          title: const LText('在动作时长内循环'),
          value: repeat,
          onChanged: (v) => setState(() => repeat = v),
        ),
        if (receipt.isNotEmpty)
          LText(receipt, key: const Key('channel_receipt')),
      ],
    );
  }
}

class PatternLibrary extends StatelessWidget {
  const PatternLibrary({super.key, required this.state, required this.act});
  final Map<String, dynamic> state;
  final ControlAction act;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const LText('24 种内置波形'),
    subtitle: const LText('原创参数化波形 · 可导出 JSON 预览'),
    children: [
      for (final p in state['pattern_catalog'] as List? ?? [])
        ListTile(
          title: LText(
            p[LanguageScope.of(context) == 'en' ? 'name_en' : 'name'] as String,
          ),
          subtitle: LText(
            '${p['name_en']} · ${(p['duration_ms'] as num) / 1000}s',
          ),
          trailing: Wrap(
            spacing: 4,
            children: [
              IconButton(
                tooltip: '播放内置波形',
                onPressed: ['authorized', 'playing'].contains(state['phase'])
                    ? () => act({'op': 'play', 'preset_id': p['id']})
                    : null,
                icon: const Icon(Icons.play_arrow),
              ),
              IconButton(
                tooltip: '导出波形',
                onPressed: () async {
                  final result = act({
                    'op': 'export_pattern',
                    'preset_id': p['id'],
                    'electrical': state['device']?['id'] == 'sim_dglab',
                  });
                  if (result['ok'] != true || !context.mounted) return;
                  final source = const JsonEncoder.withIndent('  ')
                      .convert(result['result']['canonical']);
                  await showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: LText(p['name'] as String),
                      content: SizedBox(
                        width: 560,
                        height: 330,
                        child: SingleChildScrollView(
                          child: SelectableText(source),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: source));
                          },
                          child: const LText('复制 JSON'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const LText('关闭'),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.download_outlined),
              ),
            ],
          ),
        ),
    ],
  );
}
