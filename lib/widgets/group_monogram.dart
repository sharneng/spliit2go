import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';
import 'text_scaled.dart';

// Matches spliit-ios MonogramPalette; see THIRD_PARTY_NOTICES.md.
int groupColorIndex(String id) {
  // Only the low three FNV-1a bits affect modulo eight. Keeping those
  // bits avoids platform-dependent integer overflow, including on web.
  var hash = 5;
  for (final byte in utf8.encode(id)) {
    hash = ((hash ^ byte) * 3) & 7;
  }
  return hash;
}

String groupInitials(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((word) => word.isNotEmpty)
    .take(2)
    .map((word) => word.characters.first)
    .join()
    .toUpperCase();

class GroupMonogram extends StatelessWidget {
  const GroupMonogram({super.key, required this.id, required this.name});
  final String id;
  final String name;
  @override
  Widget build(BuildContext context) =>
      Monogram(name: name, color: monogramPalette[groupColorIndex(id)]);
}

/// [name]'s initials in white on a [color] circle: a group's in the group
/// list, a participant's in "Who are you?" (#218).
///
/// [radius] is at the usual text size; it grows with the text (#294), and
/// the initials with it.
class Monogram extends StatelessWidget {
  const Monogram({super.key, required this.name, required this.color, this.radius = 20});
  final String name;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final radius = context.textScaled(this.radius);
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: radius,
        backgroundColor: color,
        foregroundColor: Colors.white,
        // Already scaled with the circle.
        child: Text(groupInitials(name),
            textScaler: TextScaler.noScaling,
            style: TextStyle(fontSize: radius * 0.85, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// A person's [monogram] before their [name], level with the name's first
/// line however it wraps, rather than centered on the row (Kenneth, #296):
/// Paid for's rows, in the form and the expense details.
class MonogramLabel extends StatelessWidget {
  const MonogramLabel(
      {super.key, required this.monogram, required this.name, this.nameStyle, this.glyphSize = 24});

  final Widget monogram;
  final Widget name;

  /// [name]'s style, if not the surrounding text's, to find its line.
  final TextStyle? nameStyle;

  /// The monogram's size at the usual text size.
  final double glyphSize;

  @override
  Widget build(BuildContext context) {
    final painter = TextPainter(
        text: TextSpan(text: 'X', style: DefaultTextStyle.of(context).style.merge(nameStyle)),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context))
      ..layout();
    final line = painter.height;
    painter.dispose();
    final glyph = context.textScaled(glyphSize);
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: EdgeInsets.only(top: math.max(0, (line - glyph) / 2)), child: monogram),
      const SizedBox(width: 16),
      Flexible(child: Padding(padding: EdgeInsets.only(top: math.max(0, (glyph - line) / 2)), child: name)),
    ]);
  }
}
