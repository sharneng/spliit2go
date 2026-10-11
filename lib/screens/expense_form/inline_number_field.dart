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
/// target, or with a [label], the whole row. It owns its focus.
class InlineNumberField extends StatefulWidget {
  const InlineNumberField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.name,
    this.label,
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
              if (widget.prefix case final prefix?) Text(prefix, style: style),
              Flexible(child: field!),
              if (widget.suffix case final suffix?) Text(suffix, style: style),
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _focus.requestFocus,
      child: switch (widget.label) {
        final label? => formFieldRow(context, label, value),
        null => value,
      },
    );
  }
}
