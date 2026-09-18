import '../models/expense.dart';
import '../models/group.dart';

/// How a group's expenses are usually divided, remembered locally so the
/// next new expense in that group starts there instead of from scratch
/// every time (issue #29). A local port of spliit-ios's own `DefaultSplit`
/// -- this is a spliit2go/spliit-ios-only feature: the
/// `saveDefaultSplittingOptions` flag this app already sends to the
/// server on every save is read by nobody server-side (confirmed against
/// spliit-ios's own doc comment on the equivalent type) -- what remembers
/// a split is the device, via [AppDatabase.setDefaultSplit] /
/// [AppDatabase.defaultSplitFor], not the server.
class DefaultSplit {
  final SplitMode splitMode;

  /// Who was in the remembered split, and the exact wire-scale
  /// [ExpenseShare.shares] each of them had -- null for two different
  /// reasons depending on [splitMode]:
  ///
  /// - [SplitMode.evenly] covering every participant in the group: only
  ///   the mode is worth keeping. Naming the group as two people when a
  ///   third moves in would silently leave the newcomer out of every
  ///   expense from then on -- keeping no names at all is what makes
  ///   "everybody" stay correct as the group's membership changes.
  /// - [SplitMode.byAmount]: one expense's own dollar amounts mean
  ///   nothing for the next one. Only the mode is kept there too.
  ///
  /// Non-null for [SplitMode.evenly] excluding somebody, and for
  /// [SplitMode.byShares] / [SplitMode.byPercentage], where the specific
  /// numbers (or exclusions) are exactly what's worth remembering.
  final Map<String, int>? shares;

  const DefaultSplit({required this.splitMode, this.shares});

  /// What to remember from an expense that was just saved successfully
  /// -- [paidFor] is the already-validated payload actually sent (or
  /// about to be sent), never a draft still being typed.
  factory DefaultSplit.remembering({
    required SplitMode splitMode,
    required List<ExpenseShare> paidFor,
    required List<Participant> allParticipants,
  }) {
    final coversEveryone = splitMode == SplitMode.evenly &&
        paidFor.length == allParticipants.length &&
        paidFor.map((s) => s.participantId).toSet().containsAll(
              allParticipants.map((p) => p.id),
            );

    final worthKeepingShares = splitMode != SplitMode.byAmount && !coversEveryone;

    return DefaultSplit(
      splitMode: splitMode,
      shares: worthKeepingShares
          ? {for (final s in paidFor) s.participantId: s.shares}
          : null,
    );
  }

  /// Whether this still describes a split of [participants] -- false
  /// once it names someone no longer in the group, which is when a
  /// remembered split goes stale rather than just smaller: 70/30
  /// without the 30 isn't "70", it's a different split nobody chose.
  /// Always true when [shares] is null -- there's no membership baked
  /// into "everybody" or "the mode only" to go stale.
  bool appliesTo(List<Participant> participants) {
    final shares = this.shares;
    if (shares == null) return true;
    final present = participants.map((p) => p.id).toSet();
    return shares.keys.every(present.contains);
  }
}
