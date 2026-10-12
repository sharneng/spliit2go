import 'package:flutter/material.dart';

import '../../theme.dart';
import 'form_text.dart';

/// A number typed at a row's end (Kenneth, 2026-10-10): plain
/// right-aligned text on the card rather than a box, only as wide as its
/// digits, with [prefix] (a currency symbol) or [suffix] ("%") right
/// beside them, dimmed with the "0" hint until something's typed. The
/// amount and each person's value in the split are one (#289).
///
/// The text is only as wide as typed, so the whole value is the tap
/// target, or with a [label] or a [row], the whole row. A row is then one
/// element to a screen reader, named by [name] (#263): "Amount, 30",
/// "Bea, Percent, 50", with its tap target the row's. It owns its focus.
class InlineNumberField extends StatefulWidget {
  const InlineNumberField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.name,
    this.label,
    this.row,
    this.prefix,
    this.suffix,
    this.contentPadding,
  });

  /// The text field's own key, for tests and for a refused save to find.
  final Key fieldKey;
  final TextEditingController controller;

  /// What a screen reader calls it ([namedField]).
  final String name;

  /// The row's label: the field then lays out the row, label first.
  final Widget? label;

  /// Or the row around the field, for a row laid out otherwise. What in
  /// it repeats [name] is for it to leave out of the semantics.
  final Widget Function(BuildContext context, Widget field)? row;
  final String? prefix;
  final String? suffix;
  final EdgeInsetsGeometry? contentPadding;

  @override
  State<InlineNumberField> createState() => _InlineNumberFieldState();
}

class _InlineNumberFieldState extends State<InlineNumberField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    // On an iPhone, its ⓧ after the "%".
    final value = RetypeAssist(
      focus: _focus,
      controller: controller,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, field) {
          final style = controller.text.isEmpty
              ? TextStyle(color: SpliitColors.of(context).secondaryContent)
              : formValueStyle(context);
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              // The name says what it's in.
              if (widget.prefix case final prefix?) ExcludeSemantics(child: Text(prefix, style: style)),
              Flexible(child: field!),
              if (widget.suffix case final suffix?) ExcludeSemantics(child: Text(suffix, style: style)),
            ],
          );
        },
        child: IntrinsicWidth(
          child: namedField(
            widget.name,
            TextFormField(
              key: widget.fieldKey,
              controller: controller,
              focusNode: _focus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.end,
              decoration: InputDecoration(
                  hint: unreadHint(context, '0'), isDense: true, contentPadding: widget.contentPadding),
            ),
          ),
        ),
      ),
    );
    final row = switch ((widget.label, widget.row)) {
      // The label is the name.
      (final label?, _) => formFieldRow(context, ExcludeSemantics(child: label), value),
      (_, final row?) => row(context, value),
      _ => null,
    };
    final tappable = GestureDetector(behavior: HitTestBehavior.opaque, onTap: _focus.requestFocus, child: row ?? value);
    return row == null ? tappable : MergeSemantics(child: tappable);
  }
}
