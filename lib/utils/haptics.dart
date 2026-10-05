import 'package:flutter/services.dart';

/// What the app says through haptics (#179), after spliit-ios's
/// `Haptics` (see THIRD_PARTY_NOTICES.md): outcomes, not gestures. A
/// phone that buzzes at every tap teaches people to ignore it.
///
/// Nothing for tapping a row, switching tabs, opening a sheet or typing.
/// The one exception is the group list's full swipe, which marks the
/// point where letting go will act (GroupRowActions), as the platforms'
/// own mail apps do.
///
/// Flutter's notification haptics are native on both platforms:
/// `UINotificationFeedbackGenerator` on iOS, `CONFIRM`/`REJECT` on
/// Android 11+.
abstract final class Haptics {
  /// An expense was saved: the form closes on the same beat, so this is
  /// the confirmation.
  static Future<void> saved() => HapticFeedback.successNotification();

  /// A save was refused before it was sent, because the form doesn't add
  /// up. The reason is on screen; this says to go and look.
  static Future<void> refused() => HapticFeedback.errorNotification();

  /// Something was removed: an expense deleted or discarded, a group
  /// removed from this phone. Light: it reports a thing gone, after a
  /// confirmation already asked.
  static Future<void> deleted() => HapticFeedback.lightImpact();
}
