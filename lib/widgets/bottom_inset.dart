import 'dart:math' as math;

import 'package:flutter/material.dart';

/// [padding] plus the bottom safe-area inset, for a scroll view whose own
/// padding would otherwise replace it (#197).
///
/// The app no longer insets every screen above the gesture bar or home
/// indicator (#24 did, app-wide), so content can scroll down to the
/// screen's edge, and behind the group screen's floating bar. Each scroll
/// view pads its end instead, so its last row can still scroll clear. Under
/// a Scaffold's `extendBody`, the inset already includes the bar.
EdgeInsets withBottomInset(BuildContext context, EdgeInsets padding) =>
    padding.copyWith(bottom: padding.bottom + MediaQuery.paddingOf(context).bottom);

/// Where something that stops above the system's bottom bar ends, from the
/// screen's bottom: the group screen's floating tab bar, and the group
/// list's rounded end (#222), so the two line up.
///
/// On Android, the gesture bar's or the buttons' inset, which looks right
/// with either (#198 review). On iOS that would leave it high: it sits over
/// the lower part of the home indicator's inset, as iOS's own tab bar does,
/// clear of the indicator itself. 12 where there's no inset.
double bottomBarGap(BuildContext context) {
  final inset = MediaQuery.paddingOf(context).bottom;
  if (inset == 0) return 12;
  return switch (Theme.of(context).platform) {
    TargetPlatform.iOS => math.max(inset - 14, 12),
    _ => inset,
  };
}
