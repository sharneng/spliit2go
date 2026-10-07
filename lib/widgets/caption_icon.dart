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
  Widget build(BuildContext context) => Icon(icon,
      size: captionIconSize(context), color: color ?? DefaultTextStyle.of(context).style.color);
}

/// A [CaptionIcon]'s size beside text of [captionFontSize], or of the
/// surrounding text's size, at the current text size.
double captionIconSize(BuildContext context, {double? captionFontSize}) =>
    MediaQuery.textScalerOf(context)
        .scale(captionFontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14) *
    1.15;
