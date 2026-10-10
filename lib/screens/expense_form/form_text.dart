import 'package:flutter/material.dart';

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
