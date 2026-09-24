import 'package:flutter/material.dart';

/// A date-section heading in a list ("THIS WEEK", "LAST MONTH"): small
/// bold capitals in a muted color, like spliit-ios's DateBucketHeader, so
/// it reads as a divider rather than an entry. Screen readers get [title]
/// in its natural case, as a heading. Shared by the expense list and the
/// activity log (issues #88, #91).
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key});

  /// Already localized, in its natural case.
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      label: title,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title.toUpperCase(),
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.bold,
            letterSpacing: 0.72,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
