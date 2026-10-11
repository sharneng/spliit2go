import 'package:flutter/material.dart';

import '../../l10n/context_l10n.dart';
import '../../theme.dart';

/// The form's rows (Kenneth, 2026-10-10): what was entered is the main
/// content, in the primary text color; the label naming it is secondary.
/// A label that is itself tapped (a rate pair, a switch's option) stays
/// as it is.

/// A row's label, dimmed.
Text formLabel(BuildContext context, String label) =>
    Text(label, style: TextStyle(color: SpliitColors.of(context).secondaryContent));

/// A row's value at its end, at the rows' text size.
TextStyle? formValueStyle(BuildContext context) => Theme.of(context).textTheme.bodyLarge;

/// A number field's name for a screen reader, where the row shows it
/// some other way or not at all (#288): "Amount", "Cid, Shares".
/// Its placeholder goes in as [unreadHint], or the name would read
/// "Amount, 0", and still would with a value typed.
Widget namedField(String name, Widget field) => Semantics(label: name, child: field);

/// A field's placeholder that a screen reader skips, for a [namedField]:
/// [hint] as `InputDecoration.hintText` draws it, in the theme's hint
/// style.
Widget unreadHint(BuildContext context, String hint, {TextAlign textAlign = TextAlign.end}) {
  final theme = Theme.of(context);
  return ExcludeSemantics(
    child: Text(hint, textAlign: textAlign, style: theme.textTheme.bodyLarge!.merge(theme.inputDecorationTheme.hintStyle)),
  );
}

/// A number field's [child], made quick to retype (Kenneth, 2026-10-11):
/// a number is mostly typed over, not edited, and neither platform lets
/// an app add a clear key to its number pad.
/// - On Android, focusing it selects all of [controller]'s text, so the
///   first key typed replaces it; a second tap places the cursor.
/// - On an iPhone, a ⓧ at its end while it's being edited and has text,
///   as iOS's own fields (`clearButtonMode = .whileEditing`). Selecting
///   all was tried there, and fought iOS's text handling: a tap on a
///   selection opens Cut/Copy/Paste, and the handles came and went.
///
/// [onCleared] runs after the ⓧ empties it, as typing would call
/// onChanged.
class RetypeAssist extends StatefulWidget {
  const RetypeAssist(
      {super.key, required this.focus, required this.controller, this.onCleared, required this.child});

  final FocusNode focus;
  final TextEditingController controller;
  final VoidCallback? onCleared;
  final Widget child;

  static bool _cupertino(BuildContext context) =>
      const {TargetPlatform.iOS, TargetPlatform.macOS}.contains(Theme.of(context).platform);

  @override
  State<RetypeAssist> createState() => _RetypeAssistState();
}

class _RetypeAssistState extends State<RetypeAssist> {
  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(RetypeAssist old) {
    super.didUpdateWidget(old);
    if (old.focus != widget.focus) {
      old.focus.removeListener(_focusChanged);
      widget.focus.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    widget.focus.removeListener(_focusChanged);
    super.dispose();
  }

  void _focusChanged() {
    if (!widget.focus.hasFocus || RetypeAssist._cupertino(context)) return;
    // After the frame: the tap that focused the field places the cursor
    // first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.focus.hasFocus) return;
      final controller = widget.controller;
      controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!RetypeAssist._cupertino(context)) return widget.child;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.focus, widget.controller]),
      builder: (context, child) => Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: child!),
        if (widget.focus.hasFocus && widget.controller.text.isNotEmpty)
          // Part of the field's tap region: tapping it keeps the keyboard.
          TextFieldTapRegion(
            child: Semantics(
              button: true,
              label: context.l10n.commonClear,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  widget.controller.clear();
                  widget.onCleared?.call();
                },
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 6, top: 4, bottom: 4),
                  child: Icon(Icons.cancel, size: 18, color: SpliitColors.of(context).secondaryContent),
                ),
              ),
            ),
          ),
      ]),
      child: widget.child,
    );
  }
}
