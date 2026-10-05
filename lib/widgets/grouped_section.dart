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
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, spacing),
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

  /// The card's corners.
  static const double radius = 20;

  /// The space under a card, before the next caption.
  static const double spacing = 24;

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
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (caption != null || captionTrailing != null)
            GroupedCaption(caption, trailing: captionTrailing),
          Material(
            color: cardColor(context),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
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

/// A section's caption: its title in natural case, with an optional
/// [trailing] value or button at the other end. [GroupedSection] draws its
/// own; a lazy list ([GroupedItem]) puts one before each section's rows.
class GroupedCaption extends StatelessWidget {
  const GroupedCaption(this.caption, {super.key, this.trailing, this.margin = EdgeInsets.zero});

  final String? caption;
  final Widget? trailing;

  /// Outside the caption's own padding: a lazy list's inset from the
  /// screen's edges, which [GroupedSection] gives it otherwise.
  final EdgeInsetsGeometry margin;

  /// A lazy list's caption, inset like its [GroupedItem]s.
  static const listMargin = EdgeInsets.symmetric(horizontal: 16);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caption = this.caption;
    return Padding(
      padding: margin.add(const EdgeInsets.fromLTRB(16, 0, 8, 6)),
      // A Wrap, not a Row: when the two don't fit on one line (a long
      // split mode at large text, #183 review), the trailing one goes
      // under the caption instead of overflowing, and each wraps within
      // the width.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        children: [
          if (caption != null)
            Semantics(
              header: true,
              child: Text(caption,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            )
          else
            const SizedBox.shrink(),
          if (trailing case final trailing?) trailing,
        ],
      ),
    );
  }
}

/// One row of a section in a long, lazily built list (#185), drawn as its
/// piece of the section's card: the [first] row has the card's top
/// corners, the [last] its bottom ones and the space after it, and every
/// other row starts with a hairline. A [GroupedSection] builds all its rows
/// at once; this lets a [ListView.builder] build only the visible ones and
/// still look the same.
class GroupedItem extends StatelessWidget {
  const GroupedItem({
    super.key,
    required this.first,
    required this.last,
    required this.child,
    this.dividerIndent = 16,
  });

  final bool first;
  final bool last;
  final Widget child;

  /// As [GroupedSection.dividerIndent].
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    const corner = Radius.circular(GroupedSection.radius);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, last ? GroupedSection.spacing : 0),
      child: Material(
        color: GroupedSection.cardColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: first ? corner : Radius.zero,
            bottom: last ? corner : Radius.zero,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!first) GroupedDivider(indent: dividerIndent),
            child,
          ],
        ),
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
/// decided here only (#180), unless it has a [trailing] of its own. A row
/// that opens a sheet over this screen doesn't: the chevron promises a new
/// screen (#186 review).
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

  /// The chevron, for a row that opens a screen but isn't a [GroupedRow].
  static Widget chevron(BuildContext context) =>
      Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant);

  @override
  Widget build(BuildContext context) => ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing ?? (navigates ? chevron(context) : null),
        onTap: onTap,
        selected: selected,
        enabled: enabled,
      );
}
