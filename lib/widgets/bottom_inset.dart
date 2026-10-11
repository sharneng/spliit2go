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

/// A pushed screen's scrolling body, ending above the system's bottom bar
/// as the group list does (#222), rather than scrolling behind the gesture
/// bar or the navigation buttons to the screen's edge (Kenneth,
/// 2026-10-11). In a [GroupedScrollClip] the end is rounded, as the list's.
///
/// The bottom inset is taken off [child]'s MediaQuery, so its own
/// [withBottomInset] padding doesn't count the bar twice. With the
/// keyboard up there's no bar to clear: the body already ends at the
/// keyboard.
class AboveBottomBar extends StatelessWidget {
  const AboveBottomBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final gap = MediaQuery.paddingOf(context).bottom == 0 ? 0.0 : bottomBarGap(context);
    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: MediaQuery.removePadding(context: context, removeBottom: true, child: child),
    );
  }
}
