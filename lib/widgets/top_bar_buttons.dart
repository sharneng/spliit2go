import 'package:flutter/material.dart';
import 'grouped_section.dart';

/// A top bar's buttons on a card, as iOS 26's toolbars (#228): one button
/// in a circle, several side by side in one capsule. The card is the
/// cards' color, lifted by the group screen's tab bar's shadow, so the two
/// bars read as one set.
class TopBarButtons extends StatelessWidget {
  const TopBarButtons({super.key, required this.children, this.padding = barPadding});

  /// [IconButton]s, or widgets built on one such as an AppMenuButton.
  final List<Widget> children;

  /// Around the card. In a top bar, [barPadding]: as far from the
  /// screen's edge as the cards and the back button.
  final EdgeInsetsGeometry padding;

  static const EdgeInsetsGeometry barPadding =
      EdgeInsetsDirectional.only(start: 8, end: GroupedSection.inset);

  /// The card's height, and a single button's circle: iOS's 44.
  static const double size = 44;

  /// Each button's tap target (#263): Android's 48, Material's padded
  /// target, around the same 44 circle; on an iPhone, the circle, Apple's
  /// 44. A slot that isn't a button, such as ✓'s spinner, is this size.
  static double slotSize(BuildContext context) => _padded(context) ? kMinInteractiveDimension : size;

  static bool _padded(BuildContext context) =>
      !const {TargetPlatform.iOS, TargetPlatform.macOS}.contains(Theme.of(context).platform);

  /// The app bar's leading slot: the back button's circle in it, with the
  /// screen edge's [GroupedSection.inset] on each side.
  static const double leadingWidth = GroupedSection.inset * 2 + size;

  @override
  Widget build(BuildContext context) {
    // The card stays [size] tall; on Android the targets reach past it.
    final overhang = (slotSize(context) - size) / 2;
    return Padding(
      // Out of the padding, so the card stays where it was; with none, as
      // in the expense details' top bar, it's 2pt in.
      padding: (padding.resolve(Directionality.of(context)) - EdgeInsets.symmetric(horizontal: overhang))
          .clamp(EdgeInsets.zero, EdgeInsetsGeometry.infinity),
      child: Stack(children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.all(overhang),
            child: topBarCard(context, const SizedBox.expand()),
          ),
        ),
        IconButtonTheme(
          data: IconButtonThemeData(
              style: buttonStyle.copyWith(
                  tapTargetSize: _padded(context) ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap)),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ]),
    );
  }

  /// Each button the card's height square, with no padding of its own.
  static final buttonStyle = IconButton.styleFrom(
    fixedSize: const Size.square(size),
    minimumSize: const Size.square(size),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

/// [child] on the top bar's card: the cards' color, a capsule, lifted.
Widget topBarCard(BuildContext context, Widget child) => Material(
      color: GroupedSection.cardColor(context),
      // Lighter than the tab bar's: a hint of lift, as iOS's.
      elevation: 1,
      shadowColor: Theme.of(context).colorScheme.shadow,
      surfaceTintColor: Colors.transparent,
      // A shadow doesn't show on black, so in dark a hairline lighter
      // edge lifts it instead, as the sheets' (#239).
      shape: Theme.of(context).brightness == Brightness.dark
          ? StadiumBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.15), width: 0.5))
          : const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

/// The back and close buttons' icon in the same circle (#228), for the
/// theme's [ActionIconThemeData], so every screen's gets it.
///
/// The back button's own padding leaves it 40 of the bar's 56, so the
/// circle draws past that, at the other buttons' full size.
Widget topBarCircleIcon(BuildContext context, IconData icon) => SizedBox.square(
      dimension: 40,
      child: OverflowBox(
        minWidth: TopBarButtons.size,
        maxWidth: TopBarButtons.size,
        minHeight: TopBarButtons.size,
        maxHeight: TopBarButtons.size,
        child: topBarCard(context, Center(child: Icon(icon))),
      ),
    );
