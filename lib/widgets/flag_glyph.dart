import 'package:flutter/widgets.dart';

import 'text_scaled.dart';

/// A currency's flag, an emoji, sized as a glyph rather than as text: it
/// grows by the square root of the text's growth, as an icon does (#294),
/// not as much as the text. [size] is at the usual text size.
class FlagGlyph extends StatelessWidget {
  const FlagGlyph(this.emoji, {super.key, this.size = 20});

  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Text(emoji,
            textScaler: TextScaler.noScaling,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: context.textScaled(size), height: 1.2)),
      );
}
