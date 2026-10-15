import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

import 'autopilot.dart';
import 'character.dart';
import 'content_store.dart';
import 'experience_hub.dart';
import 'story_engine.dart';

class ExperiencePanel extends StatefulWidget {
  const ExperiencePanel({
    super.key,
    required this.hub,
    required this.auto,
    required this.stop,
    required this.roleChanged,
    required this.startAuto,
    required this.feedback,
  });
  final ExperienceHub hub;
  final Autopilot auto;
  final VoidCallback stop, roleChanged;
  final void Function(int seconds, int rounds) startAuto;
  final void Function(String pattern) feedback;
  @override
  State<ExperiencePanel> createState() => _ExperiencePanelState();
}

class _ExperiencePanelState extends State<ExperiencePanel> {
  int interval = 15, rounds = 12, slot = 1;
  bool feedback = false;
  String status = '';
  final nickname = TextEditingController(),
      seed = TextEditingController(text: '42');
  ExperienceHub get h => widget.hub;
  String t(String zh, String en) => h.tr(zh, en);
  @override
  void dispose() {
    nickname.dispose();
    seed.dispose();
    super.dispose();
  }

  Future<void> attempt(Future<void> Function() work) async {
    try {
      await work();
    } catch (e) {
      if (mounted) {
        setState(() => status = e is FormatException ? e.message : '$e');
      }
    }
  }

  Future<void> editRole() async {
    final edit = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(h.character.toJson()),
    );
    var error = '';
    final card = await showDialog<CharacterCard>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(t('编辑角色卡', 'Edit character card')),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t(
                      '修改 ID 可另存为新角色。示例对话最多 6 条；不会改变设备控制权限。',
                      'Change the ID to save a new character. Up to 6 example turns; device permissions stay under local control.',
                    ),
                  ),
                  TextField(
                    controller: edit,
                    maxLines: 16,
                    decoration: const InputDecoration(
                      labelText: 'Character JSON',
                    ),
                  ),
                  if (error.isNotEmpty) Text(error),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                try {
                  Navigator.pop(
                    context,
                    CharacterCard.parse(jsonDecode(edit.text)),
                  );
                } catch (_) {
                  update(
                    () => error = t('角色 JSON 格式不正确', 'Invalid character JSON'),
                  );
                }
              },
              child: Text(t('保存', 'Save')),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    edit.dispose();
    if (card != null) {
      widget.roleChanged();
      await h.editCharacter(card);
    }
  }

  Future<void> importPack() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Haptics content', extensions: ['json', 'zip']),
      ],
    );
    if (file == null) return;
    if (await file.length() > 1048576) {
      throw const FormatException('文件不能超过 1 MiB');
    }
    final pack = ContentPack.decode(await file.readAsBytes());
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(pack.name),
        content: SingleChildScrollView(
          child: Text(
            [
              t('安装前预览', 'Review content before installing'),
              '${t('角色', 'Characters')}: ${pack.characters.map((c) => c.title(h.language)).join(', ')}',
              '${t('剧情', 'Stories')}: ${pack.stories.map((s) => s.title(h.language)).join(', ')}',
              '${t('波形', 'Waveforms')}: ${pack.waveforms.map((w) => w['id']).join(', ')}',
            ].join('\n\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('安装到本机', 'Install locally')),
          ),
        ],
      ),
    );
    if (accepted == true) await h.install(pack);
  }

  Future<void> exportTemplate() async {
    final pack = ContentPack.parse({
      'format': 'haptics_content_v1',
      'id': 'my_content',
      'name': 'My content',
      'characters': [h.character.toJson()],
      'stories': [originalStory().data],
      'waveforms': [],
    });
    await Clipboard.setData(
      ClipboardData(
        text: const JsonEncoder.withIndent('  ').convert(pack.toJson()),
      ),
    );
    if (mounted) {
      setState(
        () => status = t(
          '内容包模板 JSON 已复制，可编辑后导入；ZIP 中只放 haptics-content.json。',
          'Content template copied. ZIP packages contain only haptics-content.json.',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: h,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('角色与互动', 'Characters & interaction'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (h.loading) Text(t('正在读取本机内容…', 'Loading local content…')),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: ValueKey('role-${h.selectedRole}'),
              initialValue: h.character.id,
              isExpanded: true,
              decoration: InputDecoration(labelText: t('当前角色', 'Character')),
              items: h.characters
                  .map(
                    (c) => DropdownMenuItem(
                      value: c.id,
                      child: Text(c.title(h.language)),
                    ),
                  )
                  .toList(),
              onChanged: h.loading
                  ? null
                  : (id) => attempt(() async {
                      widget.roleChanged();
                      h.selectedRole = id!;
                      await h.saveSettings();
                    }),
            ),
            Text(h.character.prompt(h.language)),
            if (h.character.hello(h.language).isNotEmpty)
              Text(
                h.character.hello(h.language),
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            if (h.language == 'en' && h.character.descriptionEn.isEmpty)
              const Text(
                'This character has no English description; showing Chinese.',
              ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: h.loading ? null : () => attempt(editRole),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(t('编辑 / 新建角色', 'Edit / new character')),
                ),
                TextButton.icon(
                  onPressed: h.loading || h.busy
                      ? null
                      : () => attempt(importPack),
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(t('导入内容包', 'Import content')),
                ),
                TextButton(
                  onPressed: () => attempt(exportTemplate),
                  child: Text(t('复制内容模板', 'Copy content template')),
                ),
              ],
            ),
            TextFormField(
              key: ValueKey('nickname-${h.loading}'),
              initialValue: h.nickname,
              maxLength: 60,
              decoration: InputDecoration(
                labelText: t('希望角色如何称呼你', 'Your preferred name'),
              ),
              onChanged: (value) => h.nickname = value,
              onFieldSubmitted: (_) => attempt(h.saveSettings),
            ),
            TextButton(
              onPressed: h.loading ? null : () => attempt(h.saveSettings),
              child: Text(t('保存角色与称呼', 'Save character & name')),
            ),
            ExpansionTile(
              title: Text(t('自动对话回合', 'Automatic conversation rounds')),
              subtitle: Text(widget.auto.status),
              children: [
                Text(
                  t(
                    '按设定间隔继续对话。设备授权到期会停止；不会自动续授权。',
                    'Continue at the chosen interval. Device authorization is never renewed automatically.',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: interval,
                        decoration: InputDecoration(
                          labelText: t('间隔（秒）', 'Interval (seconds)'),
                        ),
                        items: [5, 10, 15, 30, 60, 120]
                            .map(
                              (i) =>
                                  DropdownMenuItem(value: i, child: Text('$i')),
                            )
                            .toList(),
                        onChanged: widget.auto.active
                            ? null
                            : (v) => setState(() => interval = v!),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: rounds,
                        decoration: InputDecoration(
                          labelText: t('回合上限', 'Round limit'),
                        ),
                        items: [3, 6, 12, 24]
                            .map(
                              (i) =>
                                  DropdownMenuItem(value: i, child: Text('$i')),
                            )
                            .toList(),
                        onChanged: widget.auto.active
                            ? null
                            : (v) => setState(() => rounds = v!),
                      ),
                    ),
                  ],
                ),
                FilledButton(
                  onPressed: h.loading
                      ? null
                      : widget.auto.active
                      ? widget.stop
                      : () => widget.startAuto(interval, rounds),
                  child: Text(
                    widget.auto.active
                        ? t('停止自动回合及输出', 'Stop rounds & output')
                        : t('开始自动回合', 'Start automatic rounds'),
                  ),
                ),
              ],
            ),
            ExpansionTile(
              title: Text(t('剧情探索', 'Story exploration')),
              subtitle: Text(
                h.run?.pack.title(h.language) ??
                    t(
                      '原创分支故事 · 地图 · 存档',
                      'Original branching stories · map · saves',
                    ),
              ),
              children: [
                const SizedBox(height: 16),
                TextField(
                  controller: seed,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t(
                      '随机种子（0–2147483647）',
                      'Random seed (0–2147483647)',
                    ),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final pack in h.stories)
                      OutlinedButton(
                        onPressed: () {
                          widget.stop();
                          h.startStory(pack, int.tryParse(seed.text) ?? 42);
                        },
                        child: Text(pack.title(h.language)),
                      ),
                  ],
                ),
                if (h.run case final StoryRun run) ...[
                  Text(
                    bilingual(run.room, 'title', h.language),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(run.narrative(h.language)),
                  Wrap(
                    spacing: 8,
                    children: run.stats.entries
                        .map((e) => Chip(label: Text('${e.key}: ${e.value}')))
                        .toList(),
                  ),
                  if (run.paused)
                    FilledButton(
                      onPressed: () {
                        run.paused = false;
                        setState(() {});
                      },
                      child: Text(
                        t('继续剧情（不恢复输出）', 'Resume story (no output restored)'),
                      ),
                    ),
                  for (final choice in run.room['choices'])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: OutlinedButton(
                        onPressed: run.paused || run.unmet(choice).isNotEmpty
                            ? null
                            : () {
                                final result = h.choose(choice['id']);
                                setState(
                                  () => status = result['check'] == null
                                      ? ''
                                      : t(
                                          '检定结果：${result['check']}',
                                          'Check result: ${result['check']}',
                                        ),
                                );
                                if (feedback &&
                                    h.run!.room['pattern'] is String) {
                                  widget.feedback(h.run!.room['pattern']);
                                }
                              },
                        child: Text(
                          '${bilingual(choice, 'label', h.language)}${run.unmet(choice).isEmpty ? '' : ' · ${run.unmet(choice).join(', ')}'}',
                        ),
                      ),
                    ),
                  SwitchListTile(
                    value: feedback,
                    onChanged: (v) => setState(() => feedback = v),
                    title: Text(t('剧情节点触觉反馈', 'Story node haptic feedback')),
                    subtitle: Text(
                      t(
                        '仅在已有本地授权时执行，最长 3 秒',
                        'Requires existing local authorization; at most 3 seconds',
                      ),
                    ),
                  ),
                  ExpansionTile(
                    title: Text(t('地图与路径', 'Map & route')),
                    children: [
                      for (final room in run.pack.rooms)
                        ListTile(
                          leading: Icon(
                            room['id'] == run.roomId
                                ? Icons.my_location
                                : run.visits.containsKey(room['id'])
                                ? Icons.check_circle_outline
                                : Icons.circle_outlined,
                          ),
                          title: Text(bilingual(room, 'title', h.language)),
                          subtitle: Text(
                            (room['choices'] as List)
                                .map((c) => c['next'])
                                .join(' → '),
                          ),
                        ),
                    ],
                  ),
                  ExpansionTile(
                    title: Text(t('本局记录', 'Session log')),
                    children: [
                      for (final entry in run.log.reversed.take(12))
                        ListTile(
                          dense: true,
                          title: Text(
                            '#${entry['turn']} ${entry['from']} → ${entry['to']}',
                          ),
                          subtitle: Text(
                            '${entry['choice']} · ${entry['success']}',
                          ),
                        ),
                    ],
                  ),
                ],
                Row(
                  children: [
                    DropdownButton<int>(
                      value: slot,
                      items: [1, 2, 3]
                          .map(
                            (i) => DropdownMenuItem(
                              value: i,
                              child: Text(t('存档 $i', 'Slot $i')),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => slot = v!),
                    ),
                    TextButton(
                      onPressed: h.run == null
                          ? null
                          : () => attempt(() => h.saveStory(slot)),
                      child: Text(t('保存', 'Save')),
                    ),
                    TextButton(
                      onPressed: () => attempt(() async {
                        widget.stop();
                        await h.loadStory(slot);
                      }),
                      child: Text(t('读取', 'Load')),
                    ),
                  ],
                ),
              ],
            ),
            if (status.isNotEmpty) Text(status),
            Text(h.status, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );
}
