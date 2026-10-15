import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Avoid Material Slider's always-mounted value-indicator portal.
/// Flutter 3.47.6 left that portal pending in Windows AXTree updates and
/// Android accessibility transforms. Keep one accessible node with equivalent
/// pointer, keyboard and accessibility actions, including commit callbacks.
class ControlSlider extends StatefulWidget {
  const ControlSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.onChangeStart,
    this.onChangeEnd,
  });
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;
  @override
  State<ControlSlider> createState() => _ControlSliderState();
}

class _ControlSliderState extends State<ControlSlider> {
  final focus = FocusNode();
  bool focused = false;
  bool get enabled => widget.onChanged != null && widget.max > widget.min;
  double next(int direction) =>
      (widget.value +
              direction * (widget.max - widget.min) / (widget.divisions ?? 20))
          .clamp(widget.min, widget.max);
  String display(double value) => widget.min == 0 && widget.max == 1
      ? '${(value * 100).round()}%'
      : value.toStringAsFixed(0);
  void commit(double value) {
    if (!enabled || value == widget.value) return;
    widget.onChangeStart?.call(widget.value);
    widget.onChanged!(value);
    widget.onChangeEnd?.call(value);
  }

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      slider: true,
      enabled: enabled,
      focusable: enabled,
      focused: focused,
      value: display(widget.value),
      increasedValue: display(next(1)),
      decreasedValue: display(next(-1)),
      onIncrease: enabled ? () => commit(next(1)) : null,
      onDecrease: enabled ? () => commit(next(-1)) : null,
      onFocus: enabled ? focus.requestFocus : null,
      child: Focus(
        focusNode: focus,
        includeSemantics: false,
        canRequestFocus: enabled,
        onFocusChange: (value) => setState(() => focused = value),
        onKeyEvent: (_, event) {
          if (!enabled || event is KeyUpEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowRight ||
              key == LogicalKeyboardKey.arrowUp) {
            commit(next(1));
          } else if (key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowDown) {
            commit(next(-1));
          } else if (key == LogicalKeyboardKey.home) {
            commit(widget.min);
          } else if (key == LogicalKeyboardKey.end) {
            commit(widget.max);
          } else {
            return KeyEventResult.ignored;
          }
          return KeyEventResult.handled;
        },
        child: Listener(
          onPointerDown: enabled ? (_) => focus.requestFocus() : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: focused
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
              ),
            ),
            child: SizedBox(
              height: 48,
              width: double.infinity,
              child: CupertinoSlider(
                value: widget.value,
                min: widget.min,
                max: widget.max,
                divisions: widget.divisions,
                activeColor: Theme.of(context).colorScheme.primary,
                onChanged: widget.onChanged,
                onChangeStart: widget.onChangeStart,
                onChangeEnd: widget.onChangeEnd,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
