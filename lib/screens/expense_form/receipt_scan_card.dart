import 'package:flutter/material.dart';

import '../../l10n/context_l10n.dart';
import '../../widgets/error_message.dart';
import '../../widgets/grouped_section.dart';

/// "Scan receipt" on a new expense (#259): one row with the receipt
/// language at its end, and what the scan did in the footer.
class ReceiptScanCard extends StatelessWidget {
  const ReceiptScanCard({
    super.key,
    required this.status,
    required this.reading,
    required this.language,
    required this.onScan,
    required this.onPickLanguage,
    this.failed = false,
    this.diagnostics,
  });

  /// What the scan did, or what it will do before the first.
  final String status;

  /// A photo is being read: the row shows a spinner and takes no taps.
  final bool reading;

  /// The receipt language's short name, such as "EN".
  final String language;

  final VoidCallback onScan;
  final VoidCallback onPickLanguage;

  /// The scan failed: [status] is an error, with its [diagnostics].
  final bool failed;
  final String? diagnostics;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(GroupedSection.inset, 0, GroupedSection.inset, GroupedSection.spacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GroupedSection(
            margin: EdgeInsets.zero,
            children: [
              GroupedRow(
                leading: reading
                    ? const SizedBox.square(dimension: 24, child: Padding(
                        padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2)))
                    : Icon(Icons.document_scanner_outlined, color: theme.colorScheme.primary),
                title: Text(l10n.expenseScanReceipt,
                    style: TextStyle(color: reading ? null : theme.colorScheme.primary)),
                trailing: Tooltip(
                  message: l10n.receiptLanguage,
                  child: TextButton.icon(
                    onPressed: reading ? null : onPickLanguage,
                    icon: const Icon(Icons.translate),
                    label: Text(language),
                  ),
                ),
                enabled: !reading,
                onTap: onScan,
              ),
            ],
          ),
          // The section's footer, which can be an error with its details.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: failed
                ? ErrorMessage(status, diagnostics: diagnostics)
                : Text(status,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
