import 'package:flutter/material.dart';

import 'grouped_section.dart';
import 'text_scaled.dart';

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
      constraints: appMenuConstraints(context),
      itemBuilder: (context) => [
        for (var i = 0; i < items.length; i++)
          appPopupMenuItem(context, i, items[i], choice: items.any((item) => item.checked)),
      ],
    );
  }
}

/// A form's row that picks one of a few, its [value] at the end with a
/// drop-down arrow: Repeat, and the split mode when its pill doesn't fit
/// (#263). The menu opens under the value, from its end, rather than
/// from the row's start, far from what was tapped. To a screen reader a
/// button, "Repeat, Never".
class MenuRow extends StatefulWidget {
  const MenuRow(
      {super.key, required this.title, required this.value, required this.items, this.onOpened});
  final Widget title;
  final Widget value;

  /// Its choices, the current one [AppMenuItem.checked].
  final List<AppMenuItem> items;
  final VoidCallback? onOpened;

  @override
  State<MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<MenuRow> {
  final _value = GlobalKey();

  Future<void> _open() async {
    widget.onOpened?.call();
    final anchor = _value.currentContext!.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final rect = MatrixUtils.transformRect(anchor.getTransformTo(overlay), Offset.zero & anchor.size);
    // Under the value; showMenu lines the menu up with the value's nearer
    // edge of the screen, its end here.
    final i = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
          Rect.fromLTRB(rect.left, rect.bottom, rect.right, rect.bottom), Offset.zero & overlay.size),
      constraints: appMenuConstraints(context),
      items: [
        for (final (i, item) in widget.items.indexed) appPopupMenuItem(context, i, item, choice: true),
      ],
    );
    if (i != null) widget.items[i].onSelected();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: GroupedRow(
          title: widget.title,
          value: Row(key: _value, mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: widget.value),
            // As a trailing icon was.
            Icon(Icons.arrow_drop_down, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ]),
          onTap: _open,
        ),
      );
}

/// As wide as its labels, up to the screen's width inside the cards' edges:
/// Material stops at 280, which wraps "Percent" at large text with the
/// screen beside it empty (Kenneth, #294).
BoxConstraints appMenuConstraints(BuildContext context) => BoxConstraints(
    minWidth: 2 * 56, maxWidth: MediaQuery.sizeOf(context).width - 2 * GroupedSection.inset);

/// [item] as a row of a popup menu, valued [index], its icon leading. In
/// a menu that picks one ([choice]), the current choice's emerald check
/// mark takes the icon's place, and the other rows keep the room, so the
/// labels line up as in a menu with icons (#217, Kenneth).
PopupMenuItem<int> appPopupMenuItem(BuildContext context, int index, AppMenuItem item,
    {bool choice = false}) {
  final colors = Theme.of(context).colorScheme;
  final color = item.destructive ? colors.error : null;
  final markSize = context.textScaled(24);
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
      // A row's mark, growing with the text (#294); the rows without one
      // keep its room.
      if (item.checked)
        Icon(Icons.check, size: markSize, color: colors.primary)
      else if (item.icon != null)
        Icon(item.icon, size: markSize, color: color)
      else if (choice)
        SizedBox(width: markSize),
      if (item.checked || item.icon != null || choice) const SizedBox(width: 14),
      Expanded(
          child: Text(item.label, style: color == null ? null : TextStyle(color: color))),
      ]),
    ),
  );
}
