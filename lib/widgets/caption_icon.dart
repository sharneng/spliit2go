import 'package:flutter/material.dart';

/// An icon in a row's caption, sized from the caption's own text so it
/// grows with the system text size, in the caption's color (#180). Lucide,
/// whose line drawings sit next to text the way spliit-ios's SF Symbols
/// do; Material's, drawn for 24 px, thinned to faint lines at 14.
class CaptionIcon extends StatelessWidget {
  const CaptionIcon(this.icon, {super.key, this.color});

  final IconData icon;

  /// The caption's own color when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final fontSize = MediaQuery.textScalerOf(context).scale(style.fontSize ?? 14);
    return Icon(icon, size: fontSize * 1.15, color: color ?? style.color);
  }
}
