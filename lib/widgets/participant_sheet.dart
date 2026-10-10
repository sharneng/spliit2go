import 'package:flutter/material.dart';

import '../l10n/context_l10n.dart';
import '../models/group.dart';
import 'bottom_inset.dart';
import 'expense_list.dart' show participantColors;
import 'group_monogram.dart';
import 'grouped_section.dart';

/// Picks one participant (#260), such as who paid: a sheet sliding up with
/// [title] over the group's participants, each by their monogram, the
/// [checkedId] one checked and [activeUserId] named "(you)". A pick answers
/// at once; a tap outside or a drag down answers null.
Future<String?> showParticipantSheet(
  BuildContext context, {
  required String title,
  required List<Participant> participants,
  String? checkedId,
  String? activeUserId,
}) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final colors = participantColors(participants, activeUserId);
        return SingleChildScrollView(
          padding: EdgeInsets.only(bottom: bottomBarGap(context)),
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetTitle(title),
                GroupedSection(
                  dividerIndent: ChoiceRow.monogramIndent,
                  margin: const EdgeInsets.symmetric(horizontal: GroupedSection.inset),
                  children: [
                    for (final p in participants)
                      ChoiceRow(
                        leading: Monogram(name: p.name, color: colors[p.id]!, radius: 12),
                        label: participantName(context, p, activeUserId),
                        checked: p.id == checkedId,
                        onTap: () => Navigator.of(context).pop(p.id),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

/// [p]'s name, "(you)" after it when they're [activeUserId], as the
/// expense details sheet names them.
String participantName(BuildContext context, Participant p, String? activeUserId) =>
    p.id == activeUserId ? context.l10n.expenseDetailsYou(p.name) : p.name;

/// A sheet's title, centered over its cards, as "Who are you?".
class SheetTitle extends StatelessWidget {
  const SheetTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(GroupedSection.inset, 0, GroupedSection.inset, 16),
        child: Text(title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
      );
}

/// One option of a sheet that picks one, such as a participant: the
/// current choice checked in emerald, and said to be, for a screen reader
/// too (#227 review).
class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    this.leading,
    required this.label,
    this.style,
    required this.checked,
    required this.onTap,
  });

  final Widget? leading;
  final String label;
  final TextStyle? style;
  final bool checked;
  final VoidCallback onTap;

  /// Past a small monogram: 16 + 24 + ListTile's 16 gap, where the names
  /// start.
  static const double monogramIndent = 56;

  @override
  Widget build(BuildContext context) => Semantics(
        checked: checked,
        inMutuallyExclusiveGroup: true,
        child: GroupedRow(
          leading: leading,
          // Wraps at large text sizes rather than overflowing (#87 review).
          title: Text(label, style: style),
          trailing: checked ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
          onTap: onTap,
        ),
      );
}
