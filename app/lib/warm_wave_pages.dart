import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pulse_library.dart';
import 'venice_wave_session.dart';
import 'warm_library.dart';
import 'warm_theme.dart';

class WarmWaveLibraryPage extends StatefulWidget {
  const WarmWaveLibraryPage({
    super.key,
    required this.library,
    required this.onSelected,
    this.embedded = false,
  });
  final WarmLibrary library;
  final VoidCallback onSelected;
  final bool embedded;
  @override
  State<WarmWaveLibraryPage> createState() => _WarmWaveLibraryPageState();
}

class _WarmWaveLibraryPageState extends State<WarmWaveLibraryPage> {
  String query = '', filter = '全部', category = '全部';
  bool importing = false, managing = false;
  final checked = <String>{};
  WarmLibrary get lib => widget.library;
  VeniceWaveSession get s => lib.session;
  void message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> importFile() async {
    if (importing) return;
    setState(() => importing = true);
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
      if (await file.length() > 8 * 1024 * 1024) throw const FormatException();
      await lib.importBytes(file.name, await file.readAsBytes());
      if (mounted) message(lib.notice);
    } catch (_) {
      if (mounted) message('导入失败，请选择 8 MB 以内的 .pulse 或 ZIP 文件。');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> export(PulseWave wave) async {
    try {
      final filename =
          '${wave.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.pulse';
      if (Platform.isAndroid) {
        await const MethodChannel('aihaptics/files').invokeMethod<bool>(
          'export_pulse',
          {'name': filename, 'bytes': wave.bytes},
        );
      } else {
        final target = await getSaveLocation(suggestedName: filename);
        if (target != null) {
          await XFile.fromData(wave.bytes).saveTo(target.path);
        }
      }
    } catch (_) {
      if (mounted) message('导出失败，请换一个保存位置。');
    }
  }

  void choose(PulseWave wave) {
    if (s.physical && s.active && !wave.deviceReady) {
      message('此导入波形目前支持预览，尚不能用于实物。');
      return;
    }
    if (s.active) {
      if (!s.candidates.contains(wave.id) && s.candidates.length >= 24) {
        message('AI 可选波形已满，请先移除一个。');
        return;
      }
      s.candidates.add(wave.id);
      s.invalidate('manual_waveform');
      s.apply({
        'action': 'set',
        'a': s.strength[0],
        'b': s.strength[1],
        'waveform_id': wave.id,
      }, s.epoch);
    } else {
      s.selectIdle(wave.id);
    }
    lib.markRecent(wave.id);
    widget.onSelected();
  }

  void candidate(PulseWave w, bool value) {
    if (s.active) {
      message('请结束本次互动后再修改 AI 可选范围。');
      return;
    }
    if (value && s.candidates.length >= 24) {
      message('最多允许 AI 使用 24 个波形。');
      return;
    }
    if (value) {
      s.candidates.add(w.id);
    } else {
      s.candidates.remove(w.id);
    }
    lib.save();
  }

  Future<String?> askText(
    String title, {
    String initial = '',
    int max = 16,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: max,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // Dispose after the route has completed its closing animation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    return result;
  }

  Future<void> assign(Set<String> ids) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('移动到分类')),
            for (final c in [...lib.categories, '未分类'])
              ListTile(title: Text(c), onTap: () => Navigator.pop(context, c)),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    for (final id in ids) {
      lib.assignments[id] = picked;
    }
    await lib.save();
    if (mounted) {
      setState(() {
        checked.clear();
        managing = false;
      });
    }
  }

  Future<void> manageCategories() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: lib,
      builder: (context, _) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              Text('管理分类', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              for (final c in lib.categories)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(c),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: '重命名 $c',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final name = await askText('重命名分类', initial: c);
                          if (name != null && mounted) {
                            lib.renameCategory(c, name);
                          }
                        },
                      ),
                      IconButton(
                        tooltip: '删除 $c',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => lib.removeCategory(c),
                      ),
                    ],
                  ),
                ),
              OutlinedButton.icon(
                onPressed: () async {
                  final name = await askText('新建分类');
                  if (name != null &&
                      mounted &&
                      WarmLibrary.validCategory(name) &&
                      !lib.categories.contains(name)) {
                    lib.categories.add(name);
                    await lib.save();
                  }
                },
                icon: const Icon(Icons.add),
                label: const Text('新建分类'),
              ),
              const SizedBox(height: 12),
              const Text(
                '删除分类不会删除波形，波形将移入“未分类”。',
                style: TextStyle(color: warmMuted),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> detail(PulseWave wave) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: Listenable.merge([lib, s]),
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lib.name(wave),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                SelectableText(
                  '原始名称：${wave.name}',
                  style: const TextStyle(fontSize: 11, color: warmMuted),
                ),
                const SizedBox(height: 12),
                WarmWavePlot(wave.levels, height: 120),
                const Text(
                  '分类和标签来自名称，不代表适用部位或已验证体感。形状预览非实测电流。',
                  style: TextStyle(color: warmMuted, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    WarmBadge(lib.category(wave)),
                    WarmBadge(wave.deviceReady ? '内置 · 可用于实物' : '导入 · 仅预览'),
                    for (final tag in lib.nameTags(wave)) WarmBadge(tag),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许 AI 使用'),
                  subtitle: Text('已选 ${s.candidates.length}/24 · 与收藏独立'),
                  value: s.candidates.contains(wave.id),
                  onChanged: s.active ? null : (v) => candidate(wave, v),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () => lib.toggleFavorite(wave.id),
                      icon: Icon(
                        lib.favorites.contains(wave.id)
                            ? Icons.star
                            : Icons.star_border,
                      ),
                      label: const Text('收藏'),
                    ),
                    TextButton(
                      onPressed: () => assign({wave.id}),
                      child: const Text('修改分类'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final text = await askText(
                          '编辑标签（逗号分隔）',
                          initial: (lib.tags[wave.id] ?? []).join('，'),
                          max: 80,
                        );
                        if (text != null && mounted) {
                          lib.tags[wave.id] = text
                              .split(RegExp('[,，]'))
                              .map((s) => s.trim())
                              .where(WarmLibrary.validCategory)
                              .toSet()
                              .take(6)
                              .toList();
                          await lib.save();
                        }
                      },
                      child: const Text('编辑标签'),
                    ),
                    if (!wave.deviceReady)
                      TextButton.icon(
                        onPressed: () => export(wave),
                        icon: const Icon(Icons.file_download_outlined),
                        label: const Text('原样导出'),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      choose(wave);
                    },
                    child: Text(s.active ? '切换到此波形' : '选用此波形'),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '原始文件名：${wave.name}',
                  style: const TextStyle(color: warmMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> manageCandidates() async {
    final selected = Set<String>.of(s.candidates);
    String search = '', group = '全部';
    bool onlySelected = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) => ListenableBuilder(
          listenable: s,
          builder: (context, _) {
            final rows = s.waves
                .where(
                  (w) =>
                      (!onlySelected || selected.contains(w.id)) &&
                      (group == '全部' || lib.category(w) == group) &&
                      lib.name(w).toLowerCase().contains(search.toLowerCase()),
                )
                .toList();
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: SizedBox(
                  height: MediaQuery.sizeOf(context).height * .78,
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('管理 AI 可用波形'),
                        subtitle: Text('已选 ${selected.length} 个 · 最多 24 个'),
                        trailing: IconButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                      if (s.active)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            '运行期间可浏览，请停止本次互动后修改。',
                            style: TextStyle(color: warmRose),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TextField(
                          key: const Key('candidate_search'),
                          decoration: const InputDecoration(
                            hintText: '搜索波形',
                            prefixIcon: Icon(Icons.search),
                          ),
                          onChanged: (v) => refresh(() => search = v),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: FilterChip(
                                label: Text(
                                  onlySelected
                                      ? '已选 ${selected.length}'
                                      : '全部波形',
                                ),
                                selected: onlySelected,
                                onSelected: (v) =>
                                    refresh(() => onlySelected = v),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: group,
                                items: [
                                  for (final c in [
                                    '全部',
                                    ...lib.categories,
                                    '未分类',
                                  ])
                                    DropdownMenuItem(
                                      value: c,
                                      child: Text(
                                        c,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: (v) => refresh(() => group = v!),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: rows.isEmpty
                            ? const Center(child: Text('没有匹配的波形'))
                            : ListView.builder(
                                itemCount: rows.length,
                                itemBuilder: (context, index) {
                                  final w = rows[index];
                                  return CheckboxListTile(
                                    key: ValueKey('candidate_${w.id}'),
                                    title: Text(lib.name(w)),
                                    subtitle: Text(lib.category(w)),
                                    value: selected.contains(w.id),
                                    onChanged: s.active
                                        ? null
                                        : (v) {
                                            if (v == true &&
                                                selected.length >= 24) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        '最多选择 24 个，请先移除一个。',
                                                      ),
                                                    ),
                                                  );
                                              return;
                                            }
                                            refresh(() {
                                              if (v == true) {
                                                selected.add(w.id);
                                              } else {
                                                selected.remove(w.id);
                                              }
                                            });
                                          },
                                  );
                                },
                              ),
                      ),
                      const Text(
                        '收藏与 AI 可用范围分别管理',
                        style: TextStyle(fontSize: 11, color: warmMuted),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            key: const Key('save_candidates'),
                            onPressed: s.active
                                ? null
                                : () async {
                                    s.candidates
                                      ..clear()
                                      ..addAll(selected);
                                    await lib.save();
                                    if (sheetContext.mounted) {
                                      Navigator.pop(sheetContext);
                                    }
                                  },
                            child: Text('保存选择 · ${selected.length} 个'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([lib, s]),
    builder: (context, _) {
      final shown = s.waves.where((w) {
        if (category != '全部' && lib.category(w) != category) return false;
        if (!('${w.name} ${lib.name(w)} ${lib.nameTags(w).join(' ')}')
            .toLowerCase()
            .contains(query.toLowerCase())) {
          return false;
        }
        return switch (filter) {
          '收藏' => lib.favorites.contains(w.id),
          '最近' => lib.recent.contains(w.id),
          'AI 可选' => s.candidates.contains(w.id),
          '已导入' => !w.deviceReady,
          _ => true,
        };
      }).toList();
      if (filter == '最近') {
        shown.sort(
          (a, b) =>
              lib.recent.indexOf(a.id).compareTo(lib.recent.indexOf(b.id)),
        );
      }
      return LayoutBuilder(
        builder: (context, c) {
          final columns =
              c.maxWidth >= 350 &&
                  MediaQuery.textScalerOf(context).scale(14) < 21
              ? 2
              : 1;
          return CustomScrollView(
            key: const PageStorageKey('warm_wave_scroll'),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.embedded
                                  ? '波形库'
                                  : '波形库 · ${s.waves.length} 个',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          PopupMenuButton<String>(
                            tooltip: '波形管理',
                            onSelected: (v) {
                              switch (v) {
                                case 'import':
                                  importFile();
                                case 'category':
                                  manageCategories();
                                case 'batch':
                                  setState(() => managing = !managing);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'import',
                                child: Text('导入波形'),
                              ),
                              PopupMenuItem(
                                value: 'category',
                                child: Text('管理分类'),
                              ),
                              PopupMenuItem(
                                value: 'batch',
                                child: Text('批量整理'),
                              ),
                            ],
                            child: const Padding(
                              padding: EdgeInsets.all(10),
                              child: Text(
                                '管理',
                                style: TextStyle(color: warmRose),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          key: const Key('manage_candidates'),
                          onPressed: manageCandidates,
                          icon: const Icon(Icons.auto_awesome, size: 16),
                          label: Text('AI 可用 · 已选 ${s.candidates.length} 个'),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        key: const Key('wave_search'),
                        decoration: const InputDecoration(
                          hintText: '搜索名称或标签',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => query = v),
                      ),
                      const SizedBox(height: 4),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final f in ['全部', '收藏', '最近', '已导入'])
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  label: Text(f),
                                  selected: filter == f,
                                  onSelected: (_) => setState(() => filter = f),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final c in ['全部', ...lib.categories, '未分类'])
                            ChoiceChip(
                              key: ValueKey('category_$c'),
                              label: Text(
                                c == '全部'
                                    ? '全部分类'
                                    : '$c ${s.waves.where((w) => lib.category(w) == c).length}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              selected: category == c,
                              onSelected: (_) => setState(() => category = c),
                            ),
                        ],
                      ),
                      if (managing)
                        Wrap(
                          spacing: 6,
                          children: [
                            TextButton(
                              onPressed: checked.isEmpty
                                  ? null
                                  : () => assign(Set.of(checked)),
                              child: Text('移动已选 ${checked.length} 个'),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                checked.clear();
                                managing = false;
                              }),
                              child: const Text('退出整理'),
                            ),
                          ],
                        ),
                      if (shown.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text('没有匹配的波形，请更换分类或搜索词。'),
                        ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent:
                        MediaQuery.textScalerOf(context).scale(14) > 21
                        ? 174
                        : 132,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: shown.length,
                  itemBuilder: (context, index) {
                    final w = shown[index];
                    return Semantics(
                      selected: s.selected == w.id,
                      child: Material(
                        color: s.selected == w.id
                            ? const Color(0xFFF5E7EB)
                            : const Color(0xFFFFFCFA),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: s.selected == w.id ? warmRose : warmLine,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: ValueKey('wave_${w.id}'),
                          onTap: () => managing
                              ? setState(() {
                                  if (!checked.add(w.id)) checked.remove(w.id);
                                })
                              : choose(w),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 4, 5, 7),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        lib.name(w),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    if (managing)
                                      Checkbox(
                                        value: checked.contains(w.id),
                                        onChanged: (v) => setState(() {
                                          if (v == true) {
                                            checked.add(w.id);
                                          } else {
                                            checked.remove(w.id);
                                          }
                                        }),
                                      )
                                    else
                                      IconButton(
                                        tooltip: '收藏 ${lib.name(w)}',
                                        onPressed: () =>
                                            lib.toggleFavorite(w.id),
                                        icon: Icon(
                                          lib.favorites.contains(w.id)
                                              ? Icons.star
                                              : Icons.star_border,
                                          size: 18,
                                          color: warmRose,
                                        ),
                                        constraints: const BoxConstraints(
                                          minWidth: 32,
                                          minHeight: 36,
                                        ),
                                        padding: EdgeInsets.zero,
                                      ),
                                    IconButton(
                                      key: ValueKey('wave_details_${w.id}'),
                                      tooltip: '波形详情',
                                      onPressed: () => detail(w),
                                      icon: const Icon(
                                        Icons.more_horiz,
                                        size: 18,
                                      ),
                                      constraints: const BoxConstraints(
                                        minWidth: 28,
                                        minHeight: 36,
                                      ),
                                      padding: EdgeInsets.zero,
                                    ),
                                  ],
                                ),
                                Expanded(
                                  child: WarmWavePlot(w.levels, height: 34),
                                ),
                                if (lib.nameTags(w).isNotEmpty)
                                  Text(
                                    lib
                                        .nameTags(w)
                                        .take(3)
                                        .map((t) => '#$t')
                                        .join('  '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: warmRose,
                                    ),
                                  ),
                                Text(
                                  '${lib.category(w)}${s.selected == w.id ? ' · 当前' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: warmMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
