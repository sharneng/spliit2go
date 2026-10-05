import 'package:flutter/animation.dart';

/// The speed content changes in place (#179), after spliit-ios's
/// `Motion` (see THIRD_PARTY_NOTICES.md). Page transitions and press
/// feedback are the platform's and stay that way; this is for what the
/// platform has no opinion about, like an amount changing. Nothing
/// bounces.
abstract final class Motion {
  static const duration = Duration(milliseconds: 220);
  static const curve = Curves.easeInOut;
}
