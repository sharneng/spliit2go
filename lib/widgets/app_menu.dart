import 'package:flutter/material.dart';

/// One entry of an [AppMenuButton] or a row's long-press menu.
class AppMenuItem {
  const AppMenuItem(
      {required this.label,
      required this.onSelected,
      this.icon,
      this.checked = false,
      this.destructive = false,
      this.enabled = true});
  final String label;
  final VoidCallback onSelected;
  final IconData? icon;

  /// The current choice of a menu that picks one, such as a sort order.
  final bool checked;
  final bool destructive;
  final bool enabled;
}

/// A toolbar button that opens a menu, as the theme's [PopupMenuThemeData]
/// styles it after One UI's (#217), on every platform.
class AppMenuButton extends StatelessWidget {
  const AppMenuButton(
      {super.key, required this.icon, required this.tooltip, required this.items});
  final Widget icon;
  final String tooltip;
  final List<AppMenuItem> items;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      icon: icon,
      tooltip: tooltip,
      onSelected: (i) => items[i].onSelected(),
      itemBuilder: (context) => [
        for (var i = 0; i < items.length; i++)
          appPopupMenuItem(context, i, items[i], choice: items.any((item) => item.checked)),
      ],
    );
  }
}

/// [item] as a row of a popup menu, valued [index], its icon leading. In
/// a menu that picks one ([choice]), the current choice's emerald check
/// mark takes the icon's place, and the other rows keep the room, so the
/// labels line up as in a menu with icons (#217, Kenneth).
PopupMenuItem<int> appPopupMenuItem(BuildContext context, int index, AppMenuItem item,
    {bool choice = false}) {
  final colors = Theme.of(context).colorScheme;
  final color = item.destructive ? colors.error : null;
  return PopupMenuItem<int>(
    value: index,
    enabled: item.enabled,
    // Rows closer than Material's 48, as One UI's menus.
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 20),
    // A pick-one row says whether it's the current choice, as a radio
    // button would: the check mark itself is only drawn (#227 review).
    child: Semantics(
      checked: choice ? item.checked : null,
      inMutuallyExclusiveGroup: choice ? true : null,
      child: Row(children: [
      if (item.checked)
        Icon(Icons.check, color: colors.primary)
      else if (item.icon != null)
        Icon(item.icon, color: color)
      else if (choice)
        const SizedBox(width: 24),
      if (item.checked || item.icon != null || choice) const SizedBox(width: 14),
      Expanded(
          child: Text(item.label, style: color == null ? null : TextStyle(color: color))),
      ]),
    ),
  );
}
