import 'package:flutter/material.dart';
import 'grouped_section.dart';

/// A top bar's buttons on a card, as iOS 26's toolbars (#228): one button
/// in a circle, several side by side in one capsule. The card is the
/// cards' color, lifted by the group screen's tab bar's shadow, so the two
/// bars read as one set.
class TopBarButtons extends StatelessWidget {
  const TopBarButtons({super.key, required this.children});

  /// [IconButton]s, or widgets built on one such as an AppMenuButton.
  final List<Widget> children;

  /// The card's height, and a single button's circle: iOS's 44.
  static const double size = 44;

  /// The app bar's leading slot: the back button's circle in it, with the
  /// screen edge's [GroupedSection.inset] on each side.
  static const double leadingWidth = GroupedSection.inset * 2 + size;

  @override
  Widget build(BuildContext context) => Padding(
        // As far from the screen's edge as the cards and the back button.
        padding: const EdgeInsetsDirectional.only(start: 8, end: GroupedSection.inset),
        child: topBarCard(
          context,
          IconButtonTheme(
            data: IconButtonThemeData(style: buttonStyle),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      );

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
      shape: const StadiumBorder(),
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
