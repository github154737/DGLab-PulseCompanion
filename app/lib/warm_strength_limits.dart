import 'package:flutter/material.dart';

import 'physical_output.dart';
import 'venice_wave_session.dart';
import 'warm_library.dart';

Future<void> showStrengthLimits(
  BuildContext context,
  WarmLibrary library,
  PhysicalOutput physical, {
  bool developerAccess = false,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => StrengthLimitsSheet(
    library: library,
    physical: physical,
    developerAccess: developerAccess,
  ),
);

class StrengthLimitsSheet extends StatefulWidget {
  const StrengthLimitsSheet({
    super.key,
    required this.library,
    required this.physical,
    this.developerAccess = false,
  });
  final WarmLibrary library;
  final PhysicalOutput physical;
  final bool developerAccess;
  @override
  State<StrengthLimitsSheet> createState() => _StrengthLimitsSheetState();
}

class _StrengthLimitsSheetState extends State<StrengthLimitsSheet> {
  late int cap = widget.library.session.cap;
  late int increase = widget.library.session.maxIncrease;
  late int step = widget.library.session.manualStep;
  bool saving = false;
  String error = '';
  bool get locked =>
      !widget.library.ready ||
      (widget.library.session.physical && widget.library.session.active) ||
      widget.physical.armed ||
      widget.physical.stopping ||
      widget.physical.unknown;

  Widget setting(
    String title,
    String key,
    int value,
    int min,
    int max,
    ValueChanged<int> change,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '$title：$value',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      Slider(
        key: Key(key),
        value: value.toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: max > min ? max - min : null,
        label: '$value',
        onChanged: locked || saving || max == min
            ? null
            : (v) => setState(() => change(v.round())),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.library.session,
      widget.physical,
      widget.library,
    ]),
    builder: (context, _) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('强度设置', style: Theme.of(context).textTheme.titleLarge),
              if (locked)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('真实设备输出或停止确认期间不能修改。请先关闭此窗口，点击停止输出，再进入设置。'),
                ),
              const SizedBox(height: 16),
              setting(
                'A / B 最高强度',
                'strength_cap',
                cap,
                0,
                VeniceWaveSession.maxConfiguredStrength,
                (v) => cap = v,
              ),
              setting(
                'AI 单次最大增幅',
                'strength_increase',
                increase,
                1,
                VeniceWaveSession.maxConfiguredStrength,
                (v) {
                  increase = v;
                  if (step > increase) step = increase;
                },
              ),
              setting(
                '手动按钮每次加减',
                'strength_manual_step',
                step,
                1,
                increase,
                (v) => step = v,
              ),
              const Text(
                '单次最大增幅是每个通道相对当前值的增加上限，不是要求 AI 每次增加这么多。降低强度不受增幅限制，停止立即归零。',
              ),
              const SizedBox(height: 12),
              Text(
                widget.developerAccess
                    ? '当前开发版强度范围为 0–50，与蓝牙原生层一致；这是设备等级，不是毫安值。到达最高强度后不会继续增加。'
                    : '可设置的强度范围为 0–50；这是设备等级，不是毫安值。到达最高强度后不会继续增加。',
              ),
              const SizedBox(height: 12),
              Text(
                '设备自身上限可能更低。静音、设备故障和断连停止继续生效；DG-LAB 回传过热状态时强度还会限制在 20 以内。${widget.developerAccess ? '模拟和实物均' : '实物输出'}不限总时长，启动从 0 开始；控制中断仍会停止。',
              ),
              const SizedBox(height: 12),
              Text(
                locked
                    ? '等待设备停止确认后，滑块和保存按钮会自动解锁。'
                    : widget.developerAccess
                    ? '模拟运行中也可修改。保存后立即生效：降低上限会同步降低模拟强度，提高上限不会自动加力。设置保存在本机。'
                    : '停止输出后可修改设置，提高上限不会自动增加强度。设置保存在本机。',
              ),
              if (error.isNotEmpty)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                children: [
                  TextButton(
                    onPressed: saving ? null : () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                  FilledButton(
                    key: const Key('save_strength_limits'),
                    onPressed: locked || saving
                        ? null
                        : () async {
                            if (locked ||
                                !widget.library.session.setLimits(
                                  cap: cap,
                                  maxIncrease: increase,
                                  manualStep: step,
                                )) {
                              return;
                            }
                            setState(() => saving = true);
                            await widget.library.save();
                            if (!mounted) return;
                            if (widget.library.notice.contains('设置保存失败')) {
                              setState(() {
                                saving = false;
                                error = widget.library.notice;
                              });
                            } else {
                              Navigator.pop(this.context);
                            }
                          },
                    child: Text(saving ? '保存中…' : '保存设置'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
