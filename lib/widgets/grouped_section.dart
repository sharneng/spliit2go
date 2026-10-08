import 'package:flutter/material.dart';

import '../theme.dart';

/// A settings-style section (#180): one rounded card, inset from the
/// screen's edges, its rows divided by lines, with an optional
/// caption above. iOS's Settings and Samsung's One UI both draw sections
/// this way, and Pixel's rounded sections are close, so it's one design
/// for both platforms rather than a platform branch.
///
/// The cards stand off every screen's background ([backgroundColor], the
/// theme's).
class GroupedSection extends StatelessWidget {
  const GroupedSection({
    super.key,
    this.caption,
    this.captionTrailing,
    this.footer,
    required this.children,
    this.dividerIndent = 16,
    this.margin = const EdgeInsets.fromLTRB(inset, 0, inset, spacing),
  });

  /// Above the card, in its natural case.
  final String? caption;

  /// At the caption's other end: a value or a small button.
  final Widget? captionTrailing;

  /// Under the card, in small muted text: what the section means, or
  /// what to do in it (#187), as iOS's section footers.
  final String? footer;

  /// The rows; a line goes between each two.
  final List<Widget> children;

  /// Where the lines start: past a row's leading icon, as on iOS and
  /// One UI, so the icons read as a column. 16 for rows with no icon.
  final double dividerIndent;

  final EdgeInsetsGeometry margin;

  /// The card's corners: as round as iOS's and One UI's (#195).
  static const double radius = 26;

  /// The cards' distance from the screen's sides.
  static const double inset = 16;

  /// The space under a card, before the next caption.
  static const double spacing = 24;

  /// The card's color, a step lighter than [backgroundColor].
  static Color cardColor(BuildContext context) => cardColorOf(Theme.of(context).colorScheme);

  /// [cardColor] from the [scheme] itself, for the theme to use.
  static Color cardColorOf(ColorScheme scheme) => scheme.brightness == Brightness.light
      ? scheme.surfaceContainerLowest
      // A step off the black page, like iOS's #1C1C1E (#211).
      : scheme.surfaceContainer;

  /// The page behind the cards: every screen's, from the theme.
  static Color backgroundColor(BuildContext context) =>
      Theme.of(context).scaffoldBackgroundColor;

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
            child: _CardRows(
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
          ),
          if (footer case final footer?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(footer,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
  static const listMargin = EdgeInsets.symmetric(horizontal: GroupedSection.inset);

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
              // The rows' title size, bold, so a header still reads as
              // one in the dimmed color (#211, Kenneth).
              child: Text(caption,
                  style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w700, color: SpliitColors.of(context).secondaryContent)),
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
/// other row starts with a line. A [GroupedSection] builds all its rows
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
      padding: EdgeInsets.fromLTRB(GroupedSection.inset, 0, GroupedSection.inset,
          last ? GroupedSection.spacing : 0),
      child: Material(
        color: GroupedSection.cardColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: first ? corner : Radius.zero,
            bottom: last ? corner : Radius.zero,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: _CardRows(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!first) GroupedDivider(indent: dividerIndent),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// The line between two rows of a [GroupedSection]. A row widget that
/// builds several rows itself puts these between them.
///
/// As iOS's and One UI's (#213, Kenneth): in light mode the page's own
/// color, as if the card were cut through to the page behind it; in dark
/// mode, where the page is black, a line a little brighter than the card,
/// as iOS draws them ([darkColor]). A point thick, since in those
/// colors a single device pixel all but disappears; and stopping where
/// the rows' content does rather than running to the card's edge.
class GroupedDivider extends StatelessWidget {
  const GroupedDivider({super.key, this.indent = 16, this.endIndent = GroupedSection.inset});

  final double indent;

  /// Where it stops, from the card's end edge: by default where a card's
  /// rows end their content (see [_CardRows]); 0 in a cell that pads its
  /// content itself (#214 review).
  final double endIndent;

  static const double thickness = 1;

  /// The dark card's own color made lighter, same hue and saturation,
  /// until it stands off the card as much as iOS's dark `separator`
  /// stands off iOS's card: #3E3E41 on #1C1C1E, 1.60:1 (#213, Kenneth).
  static const darkColor = Color(0xff37443B);

  static Color colorOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? darkColor
          : GroupedSection.backgroundColor(context);

  @override
  Widget build(BuildContext context) => Divider(
        height: thickness,
        thickness: thickness,
        indent: indent,
        endIndent: endIndent,
        color: colorOf(context),
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

  /// The chevron, for a row that opens a screen but isn't a [GroupedRow]:
  /// dim, near the card's edge, as iOS's (#195). It hints; the row's own
  /// text and value come first.
  static Widget chevron(BuildContext context) =>
      Icon(Icons.chevron_right, color: chevronColor(context));

  /// The text color at 30%, as iOS's tertiary label, which its chevrons
  /// use (#196 review).
  static Color chevronColor(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3);

  /// A single-line row's least height (#233), under the theme's density's
  /// 52. For one line only: [ListTile]'s minimum height replaces its
  /// default for every line count, and isn't adjusted by the density.
  static const double oneLineMinHeight = 48;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        minTileHeight: subtitle == null ? oneLineMinHeight : null,
        trailing: trailing ?? (navigates ? chevron(context) : null),
        onTap: onTap,
        selected: selected,
        enabled: enabled,
      );
}

/// A card's rows: their trailing ends ([GroupedRow.chevron], a value or a
/// switch) [GroupedSection.inset] from the card's edge, as their leading
/// ones, rather than [ListTile]'s wider 24 (#195).
class _CardRows extends StatelessWidget {
  const _CardRows({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ListTileTheme.merge(
        contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: GroupedSection.inset),
        child: child,
      );
}

/// Clips a grouped list's scroll view to a rounded rectangle at the cards'
/// inset (#193), as One UI does: a card scrolling under the app bar or off
/// the bottom goes out through a curve matching its corners rather than a
/// straight cut across the screen. Wrap the scroll view, inside any
/// [RefreshIndicator] so the indicator isn't clipped.
class GroupedScrollClip extends StatelessWidget {
  const GroupedScrollClip({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ClipRRect(clipper: const _InsetClipper(), child: child);
}

class _InsetClipper extends CustomClipper<RRect> {
  const _InsetClipper();

  @override
  RRect getClip(Size size) => RRect.fromLTRBR(GroupedSection.inset, 0,
      size.width - GroupedSection.inset, size.height, const Radius.circular(GroupedSection.radius));

  @override
  bool shouldReclip(_InsetClipper oldClipper) => false;
}
