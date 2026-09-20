import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

/// One action shared by the anchored menu and swipe panes.
class GroupRowAction {
  const GroupRowAction(
      {required this.label,
      required this.icon,
      required this.onSelected,
      this.destructive = false});
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool destructive;
}

/// Keeps the row uncluttered: swipe to reveal actions, or open the same
/// anchored menu from the row's long press and monogram button.
class GroupRowActions extends StatefulWidget {
  const GroupRowActions(
      {super.key, required this.actions, required this.builder});
  // Favorite, archive, remove, in that order.
  final List<GroupRowAction> actions;
  final Widget Function(BuildContext, VoidCallback openMenu) builder;

  @override
  State<GroupRowActions> createState() => _GroupRowActionsState();
}

class _GroupRowActionsState extends State<GroupRowActions>
    with SingleTickerProviderStateMixin {
  late final SlidableController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SlidableController(this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Offset? _pressPosition;
  bool _menuOpen = false;

  Future<void> _openMenu() async {
    if (_menuOpen) return;
    _menuOpen = true;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final row = context.findRenderObject()! as RenderBox;
    final anchor =
        _pressPosition ?? row.localToGlobal(row.size.center(Offset.zero));
    _pressPosition = null;
    final localAnchor = overlay.globalToLocal(anchor);
    final actions = widget.actions;
    try {
      final selected = await showMenu<int>(
        context: context,
        position: RelativeRect.fromRect(
            Rect.fromLTWH(localAnchor.dx, localAnchor.dy, 1, 1),
            Offset.zero & overlay.size),
        // The popup route clamps the menu to safe screen edges and scrolls
        // when necessary. Text can wrap instead of truncating French labels.
        constraints: BoxConstraints.tightFor(
            width: (overlay.size.width - 32).clamp(0, 320)),
        items: [
          for (var i = 0; i < actions.length; i++)
            PopupMenuItem<int>(
                value: i,
                child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Icon(actions[i].icon,
                          color: actions[i].destructive
                              ? Theme.of(context).colorScheme.error
                              : null),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Text(actions[i].label,
                              style: actions[i].destructive
                                  ? TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error)
                                  : null)),
                    ]))),
        ],
      );
      if (mounted && selected != null) actions[selected].onSelected();
    } finally {
      _menuOpen = false;
    }
  }

  Widget _swipeAction(GroupRowAction action) {
    final colors = Theme.of(context).colorScheme;
    return CustomSlidableAction(
      autoClose: false,
      onPressed: (actionContext) async {
        // Finish closing before the action can move/remove this row.
        await Slidable.of(actionContext)?.close();
        if (mounted) action.onSelected();
      },
      backgroundColor:
          action.destructive ? colors.error : colors.secondaryContainer,
      foregroundColor:
          action.destructive ? colors.onError : colors.onSecondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
          message: action.label,
          child: Semantics(
              label: action.label,
              excludeSemantics: true,
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(action.icon),
                    const SizedBox(height: 4),
                    Flexible(
                        child: Text(action.label,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis)),
                  ]))),
    );
  }

  DismissiblePane _fullSwipe(GroupRowAction action) => DismissiblePane(
        // Organization changes keep the row in the list. Close the pane before
        // applying the action, then veto Slidable's permanent row dismissal.
        confirmDismiss: () async {
          await _controller.close();
          if (mounted) action.onSelected();
          return false;
        },
        onDismissed: () {},
      );

  @override
  Widget build(BuildContext context) => Slidable(
        key: ObjectKey(this),
        controller: _controller,
        groupTag: 'groups',
        startActionPane: ActionPane(
            motion: const ScrollMotion(),
            extentRatio: 0.3,
            dismissible: _fullSwipe(widget.actions[0]),
            children: [_swipeAction(widget.actions[0])]),
        endActionPane: ActionPane(
            motion: const ScrollMotion(),
            extentRatio: 0.6,
            dismissible: _fullSwipe(widget.actions[1]),
            children: [
              _swipeAction(widget.actions[2]),
              _swipeAction(widget.actions[1])
            ]),
        // Full swipes only change organization; Remove remains an explicit tap.
        child: Listener(
            onPointerDown: (event) => _pressPosition = event.position,
            child: widget.builder(context, _openMenu)),
      );
}
