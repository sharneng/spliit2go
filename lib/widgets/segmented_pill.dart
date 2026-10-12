import 'package:flutter/material.dart';

import 'grouped_section.dart';

/// A choice of a few, as iOS 26's segmented control (Kenneth, 2026-10-10,
/// after spliit-ios): a pill-shaped track in the screen's background
/// color, and the chosen segment on a pill-shaped thumb in the cards'
/// color that slides to it. Flutter's CupertinoSlidingSegmentedControl
/// was tried first; its corners are fixed and far less round.
class SegmentedPill<T> extends StatelessWidget {
  const SegmentedPill(
      {super.key, required this.segments, required this.selected, required this.onChanged, this.tapPadding = EdgeInsets.zero});

  /// Each choice and its label, in order.
  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Room around the pill that its segments' tap targets reach into
  /// (#263): the pill is 35pt tall, under the 44 and 48 the platforms ask.
  final EdgeInsets tapPadding;

  static const _inset = 3.0;

  /// Above and below a segment's text, inside the thumb.
  static const _textGap = 7.0;
  static const _duration = Duration(milliseconds: 220);

  /// A segment's text: 15pt, the chosen one semibold, the others regular.
  static TextStyle _textStyle(Color color, bool selected) =>
      TextStyle(fontSize: 15, color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w400);

  /// Whether every label fits its segment on one line in [width], semibold
  /// as when it's chosen, at the screen's text size (#263). Where one
  /// doesn't, a menu is clearer than a cut-off word.
  bool fits(BuildContext context, double width) {
    final segment = (width - tapPadding.horizontal - 2 * _inset) / segments.length - 2 * _textMargin;
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    try {
      return segments.values.every((label) {
        painter
          ..text = TextSpan(text: label, style: DefaultTextStyle.of(context).style.merge(_textStyle(Colors.black, true)))
          ..layout();
        return painter.width <= segment;
      });
    } finally {
      painter.dispose();
    }
  }

  /// Either side of a segment's text.
  static const _textMargin = 4.0;

  @override
  Widget build(BuildContext context) {
    final values = segments.keys.toList();
    final index = values.indexOf(selected);
    final textColor = Theme.of(context).colorScheme.onSurface;
    // The track and its sliding thumb, inside the tap padding; the
    // segments over them, each as tall as the padding and the track.
    final track = Padding(
      padding: tapPadding,
      child: DecoratedBox(
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
            ]);
          }),
        ),
      ),
    );
    return Stack(children: [
      Positioned.fill(child: track),
      Padding(
        padding: EdgeInsets.only(left: tapPadding.left + _inset, right: tapPadding.right + _inset),
        child: Row(children: [
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
                    padding: EdgeInsets.fromLTRB(_textMargin, tapPadding.top + _inset + _textGap, _textMargin,
                        tapPadding.bottom + _inset + _textGap),
                    child: AnimatedDefaultTextStyle(
                      duration: _duration,
                      style: _textStyle(textColor, value == selected),
                      child: Text(segments[value]!,
                          textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    ]);
  }
}
