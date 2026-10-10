import 'package:flutter/material.dart';

import 'grouped_section.dart';

/// A choice of a few, as iOS 26's segmented control (Kenneth, 2026-10-10,
/// after spliit-ios): a pill-shaped track in the screen's background
/// color, and the chosen segment on a pill-shaped thumb in the cards'
/// color that slides to it. Flutter's CupertinoSlidingSegmentedControl
/// was tried first; its corners are fixed and far less round.
class SegmentedPill<T> extends StatelessWidget {
  const SegmentedPill({super.key, required this.segments, required this.selected, required this.onChanged});

  /// Each choice and its label, in order.
  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  static const _inset = 3.0;
  static const _duration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final values = segments.keys.toList();
    final index = values.indexOf(selected);
    final textColor = Theme.of(context).colorScheme.onSurface;
    return DecoratedBox(
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: GroupedSection.backgroundColor(context)),
      child: Padding(
        padding: const EdgeInsets.all(_inset),
        child: LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth / values.length;
          return Stack(children: [
            AnimatedPositionedDirectional(
              duration: _duration,
              curve: Curves.easeOutCubic,
              start: width * index,
              width: width,
              top: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: const StadiumBorder(),
                  color: GroupedSection.cardColor(context),
                  shadows: const [BoxShadow(color: Color(0x1F000000), blurRadius: 6, offset: Offset(0, 2))],
                ),
              ),
            ),
            Row(children: [
              for (final value in values)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: value == selected,
                    inMutuallyExclusiveGroup: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // No haptic: iOS's own ticks only while dragging.
                      onTap: value == selected ? null : () => onChanged(value),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                        child: AnimatedDefaultTextStyle(
                          duration: _duration,
                          // 15pt, the chosen one semibold, the others regular.
                          style: TextStyle(
                            fontSize: 15,
                            color: textColor,
                            fontWeight: value == selected ? FontWeight.w600 : FontWeight.w400,
                          ),
                          child: Text(segments[value]!,
                              textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ]);
        }),
      ),
    );
  }
}
