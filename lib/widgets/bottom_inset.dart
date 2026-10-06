import 'package:flutter/widgets.dart';

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
