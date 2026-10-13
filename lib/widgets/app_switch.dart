import 'package:flutter/material.dart';

import 'overhang.dart';

/// The app's on/off switch: the platform's (adaptive), drawn at iOS 26's
/// height (Kenneth, 2026-10-13). Flutter draws iOS's switch as it was
/// before iOS 26, 31pt tall, and Material's 32pt; iOS 26's is 28pt, and
/// One UI's smaller still.
///
/// It takes only the room it draws in: its 48pt tap target reaches over
/// the padding around it ([Overhang]) rather than pushing its row taller,
/// as iOS's controls do. Its parent must be 48pt tall to take those taps,
/// as a [GroupedRow] is; a whole row that toggles it is a target anyway.
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// iOS 26's 28pt over Flutter's 31.
  static const scale = 0.9;

  /// The track Flutter draws, unscaled: iOS's, a point under Material's.
  static const _trackHeight = 31.0;

  @override
  Widget build(BuildContext context) => Overhang(
        // The tap target's 48 down to the drawn track's.
        reach: (kMinInteractiveDimension - _trackHeight * scale) / 2,
        child: Transform.scale(
          scale: scale,
          // Only the drawing shrinks: taps keep the full 48.
          transformHitTests: false,
          child: Switch.adaptive(value: value, onChanged: onChanged),
        ),
      );
}
