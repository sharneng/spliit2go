import 'package:flutter/material.dart';
import '../l10n/context_l10n.dart';
import '../models/group.dart';
import '../services/active_user.dart';
import 'expense_list.dart' show participantColors;
import 'bottom_inset.dart';
import 'group_monogram.dart';
import 'grouped_section.dart';

/// An answer to "Who are you?": a participant's id, or
/// [nobodyParticipantId]; and whether that participant's name becomes the
/// device's default name, which picks you in groups opened later (#218).
class ActiveUserChoice {
  const ActiveUserChoice(this.participantId, {this.rememberName = false});
  final String participantId;
  final bool rememberName;
}

/// "Who are you?" as a sheet sliding up, after spliit-ios's (#218). A
/// pick answers it at once; with no Cancel button, a tap outside or a drag
/// down dismisses it, answering null. [checkedId] is the choice to show
/// checked, if any, and [defaultName] the device's default name, if set.
Future<ActiveUserChoice?> showActiveUserSheet(
  BuildContext context, {
  required List<Participant> participants,
  String? checkedId,
  String? defaultName,
}) =>
    showModalBottomSheet<ActiveUserChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ActiveUserPicker(
          participants: participants, checkedId: checkedId, defaultName: defaultName),
    );

/// The sheet's content: the participants in a card, each by a monogram
/// in their color in the group's expense rows, then whether to remember
/// the name for other groups, then "Nobody" in a card of its own.
class ActiveUserPicker extends StatefulWidget {
  const ActiveUserPicker(
      {super.key, required this.participants, this.checkedId, this.defaultName});

  final List<Participant> participants;

  /// The option to show checked: a participant's id, [nobodyParticipantId],
  /// or null for none.
  final String? checkedId;

  /// The device's default name; null when it isn't set yet.
  final String? defaultName;

  @override
  State<ActiveUserPicker> createState() => _ActiveUserPickerState();
}

class _ActiveUserPickerState extends State<ActiveUserPicker> {
  /// On while the device has no default name, so a first pick sets it,
  /// as before #218; off once it has one, so picking someone else in one
  /// group doesn't change who you are in the next.
  late bool _rememberName = widget.defaultName == null;

  /// Past the monogram: 16 + 24 + ListTile's 16 gap, where the names start.
  static const _nameIndent = 56.0;

  void _pick(String id) => Navigator.of(context)
      .pop(ActiveUserChoice(id, rememberName: id != nobodyParticipantId && _rememberName));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    // As in the expense rows: you in emerald, the others in theirs.
    final colors = participantColors(widget.participants, widget.checkedId);
    // Ends as the group screen's tab bar does above the system's bottom
    // bar, not a card's spacing plus the whole inset below it.
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: bottomBarGap(context)),
      child: MediaQuery.removePadding(
        context: context,
        removeBottom: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(GroupedSection.inset, 0, GroupedSection.inset, 16),
              child: Text(l10n.groupScreenActiveUserDialogTitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
            ),
            GroupedSection(
              footer: l10n.activeUserPrivacyNote,
              dividerIndent: _nameIndent,
              children: [
                for (final p in widget.participants)
                  _option(p.id, p.name,
                      leading: Monogram(name: p.name, color: colors[p.id]!, radius: 12)),
              ],
            ),
            GroupedSection(
              footer: widget.defaultName == null
                  ? l10n.activeUserRememberNameNote
                  : l10n.activeUserRememberNameNoteSet(widget.defaultName!),
              children: [
                GroupedRow(
                  title: Text(l10n.activeUserRememberName),
                  trailing: Switch.adaptive(
                    value: _rememberName,
                    onChanged: (value) => setState(() => _rememberName = value),
                  ),
                  onTap: () => setState(() => _rememberName = !_rememberName),
                ),
              ],
            ),
            GroupedSection(
              footer: l10n.activeUserNobodyNote,
              margin: const EdgeInsets.symmetric(horizontal: GroupedSection.inset),
              children: [
                _option(nobodyParticipantId, l10n.groupScreenActiveUserNone,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _option(String id, String label, {Widget? leading, TextStyle? style}) {
    final checked = widget.checkedId == id;
    // Which one is the current choice, for a screen reader too: the check
    // mark itself is only drawn (#227 review).
    return Semantics(
      checked: checked,
      inMutuallyExclusiveGroup: true,
      child: GroupedRow(
        leading: leading,
        // Wraps at large text sizes rather than overflowing (#87 review).
        title: Text(label, style: style),
        trailing: checked ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
        onTap: () => _pick(id),
      ),
    );
  }
}
