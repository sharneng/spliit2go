import 'package:flutter/material.dart';

/// A settings-style section (#180): one rounded card, inset from the
/// screen's edges, its rows divided by hairlines, with an optional
/// caption above. iOS's Settings and Samsung's One UI both draw sections
/// this way, and Pixel's rounded sections are close, so it's one design
/// for both platforms rather than a platform branch.
///
/// Put the screen on [GroupedSection.backgroundColor] so the cards stand
/// off it.
class GroupedSection extends StatelessWidget {
  const GroupedSection({
    super.key,
    this.caption,
    this.captionTrailing,
    required this.children,
    this.dividerIndent = 16,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 24),
  });

  /// Above the card, in its natural case.
  final String? caption;

  /// At the caption's other end: a value or a small button.
  final Widget? captionTrailing;

  /// The rows; a hairline goes between each two.
  final List<Widget> children;

  /// Where the hairlines start: past a row's leading icon, as on iOS and
  /// One UI, so the icons read as a column. 16 for rows with no icon.
  final double dividerIndent;

  final EdgeInsetsGeometry margin;

  /// The card's color, a step lighter than [backgroundColor].
  static Color cardColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return scheme.brightness == Brightness.light
        ? scheme.surfaceContainerLowest
        : scheme.surfaceContainerHigh;
  }

  /// The page behind the cards.
  static Color backgroundColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return scheme.brightness == Brightness.light
        ? scheme.surfaceContainer
        : scheme.surface;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caption = this.caption;
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (caption != null || captionTrailing != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: caption == null
                        ? const SizedBox.shrink()
                        : Semantics(
                            header: true,
                            child: Text(caption,
                                style: theme.textTheme.labelLarge
                                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          ),
                  ),
                  if (captionTrailing case final trailing?) trailing,
                ],
              ),
            ),
          Material(
            color: cardColor(context),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) GroupedDivider(indent: dividerIndent),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The hairline between two rows of a [GroupedSection]. A row widget that
/// builds several rows itself puts these between them.
class GroupedDivider extends StatelessWidget {
  const GroupedDivider({super.key, this.indent = 16});

  final double indent;

  @override
  Widget build(BuildContext context) => Divider(
        height: 1,
        thickness: 1 / MediaQuery.devicePixelRatioOf(context),
        indent: indent,
        color: Theme.of(context).colorScheme.outlineVariant,
      );
}

/// One row of a [GroupedSection]: a [ListTile] on the card. A row that
/// opens another screen ([navigates]) gets a chevron on both platforms,
/// decided here only (#180), unless it has a [trailing] of its own.
class GroupedRow extends StatelessWidget {
  const GroupedRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.navigates = false,
    this.selected = false,
    this.enabled = true,
  });

  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool navigates;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing ??
            (navigates
                ? Icon(Icons.chevron_right,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)
                : null),
        onTap: onTap,
        selected: selected,
        enabled: enabled,
      );
}
