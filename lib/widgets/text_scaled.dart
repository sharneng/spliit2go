import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Glyphs that grow with the text size (#294), as iOS's SF Symbols do: an
/// icon, a monogram or a category's glyph grows by the square root of what
/// text of its size would (Kenneth, on the simulator): growing as much as
/// the text was too large. Twice the text is about 1.4 times the glyph;
/// iOS's largest size, about 3.1 times the text, about 1.8 times. On
/// Android 14 and later the text's own growth follows the system's curve,
/// which grows large sizes less than small ones.
///
/// The theme's default icon size follows it, so a plain [Icon] does
/// without asking. What doesn't grow: the top bar's buttons and what
/// matches them, and icon buttons, whose targets don't grow either.
extension TextScaled on BuildContext {
  /// [size] at the screen's text size.
  double textScaled(double size) =>
      size <= 0 ? size : size * math.sqrt(MediaQuery.textScalerOf(this).scale(size) / size);
}
