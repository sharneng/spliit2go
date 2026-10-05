import 'package:flutter/material.dart';

import '../theme.dart';
import '../utils/motion.dart';

/// How much an amount matters on the screen it's on (#178).
enum MoneySize {
  /// A balance headline or a total.
  hero,

  /// A suggested payment.
  lead,

  /// A list row.
  row,

  /// An inline aside.
  support,
}

/// Which way an amount points, carried by color only.
enum MoneySign {
  /// An expense amount: no direction, no color.
  none,
  positive,
  negative,
  settled;

  /// [cents] is a balance, negative when this participant owes.
  static MoneySign ofBalance(int cents) => cents > 0
      ? positive
      : cents < 0
          ? negative
          : settled;
}

/// Every amount the app shows on its own, in one treatment, after
/// spliit-ios's `Money` (see THIRD_PARTY_NOTICES.md): tabular figures,
/// semibold, slightly tightened, in one of four text-theme sizes so it
/// follows the system text size. Reimbursements read as an aside:
/// regular weight, italic. A changed amount fades to its new value
/// ([Motion]).
///
/// An amount inside a sentence stays plain text in that sentence.
class Money extends StatelessWidget {
  const Money(
    this.value, {
    super.key,
    this.size = MoneySize.row,
    this.sign = MoneySign.none,
    this.isReimbursement = false,
  });

  /// Already formatted by `formatMoney`.
  final String value;
  final MoneySize size;
  final MoneySign sign;
  final bool isReimbursement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final base = switch (size) {
      MoneySize.hero => text.headlineMedium,
      MoneySize.lead => text.titleLarge,
      MoneySize.row => text.bodyLarge,
      MoneySize.support => text.bodySmall,
    };
    final colors = SpliitColors.of(context);
    final color = switch (sign) {
      MoneySign.none => null,
      MoneySign.positive => colors.moneyPositive,
      MoneySign.negative => colors.moneyNegative,
      MoneySign.settled => theme.colorScheme.onSurfaceVariant,
    };
    final amount = Text(
      value,
      key: ValueKey(value),
      style: base?.copyWith(
        fontWeight: isReimbursement ? FontWeight.w400 : FontWeight.w600,
        fontStyle: isReimbursement ? FontStyle.italic : null,
        fontFeatures: const [FontFeature.tabularFigures()],
        letterSpacing: -0.2,
        color: color,
      ),
    );
    // Its own width, where a plain Text would be: at the start of a
    // stretched column, not across it.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      child: AnimatedSwitcher(
        duration: Motion.duration,
        switchInCurve: Motion.curve,
        switchOutCurve: Motion.curve,
        // Right-aligned, as amounts are, while the two overlap.
        layoutBuilder: (current, previous) => Stack(
          alignment: AlignmentDirectional.centerEnd,
          children: [...previous, if (current != null) current],
        ),
        child: amount,
      ),
    );
  }
}
