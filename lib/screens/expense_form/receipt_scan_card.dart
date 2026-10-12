import 'package:flutter/material.dart';

import '../../l10n/context_l10n.dart';
import '../../widgets/error_message.dart';
import '../../widgets/grouped_section.dart';
import '../../widgets/line_or_stack.dart';
import '../../widgets/text_scaled.dart';
import '../../widgets/receipt_language.dart';
import 'receipt_scan_controller.dart';

/// "Scan receipt" on a new expense (#259): one row with the receipt
/// language at its end, and what [scan] did in the footer.
class ReceiptScanCard extends StatelessWidget {
  const ReceiptScanCard({
    super.key,
    required this.scan,
    required this.onScan,
    required this.onPickLanguage,
  });

  final ReceiptScanController scan;
  final VoidCallback onScan;
  final VoidCallback onPickLanguage;

  /// What the scan did, or what it will do before the first.
  String _status(BuildContext context) {
    final l10n = context.l10n;
    return switch (scan.status) {
      ReceiptScanStatus.idle => l10n.expenseScanIntro,
      ReceiptScanStatus.reading => l10n.expenseScanReading,
      ReceiptScanStatus.filled => l10n.expenseScanFilled,
      ReceiptScanStatus.hintsOnly => '${l10n.expenseScanHintsOnly} ${l10n.expenseScanTryLanguage}',
      ReceiptScanStatus.nothing => '${l10n.expenseScanNothing} ${l10n.expenseScanTryLanguage}',
      ReceiptScanStatus.failed => l10n.expenseScanFailed,
      ReceiptScanStatus.modelMissing => l10n.expenseScanModelMissing(receiptScriptName(context, scan.missingScript!)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final reading = scan.reading;
    final status = _status(context);
    return GroupedSection(
      // The footer can be an error with its details.
      footerContent: [
        if (scan.status == ReceiptScanStatus.failed)
          ErrorMessage(status, diagnostics: scan.diagnostics)
        else
          Text(status, style: GroupedSection.footnoteStyle(context)),
      ],
      children: [
        GroupedRow(
          // On a line while it fits; otherwise the icon and "Scan receipt"
          // over the language, each centered (#294).
          title: LineOrStack(
            leading: reading
                ? SizedBox.square(
                    dimension: context.textScaled(24),
                    child: const Padding(padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2)))
                : Icon(Icons.document_scanner_outlined, color: theme.colorScheme.primary),
            // One line: smaller, rather than wrapping, once the line is full.
            title: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(l10n.expenseScanReceipt,
                  maxLines: 1, style: TextStyle(color: reading ? null : theme.colorScheme.primary)),
            ),
            // Its own element (#263), "Latin, Receipt language", rather than
            // "ABC" with the tooltip on the row's.
            trailing: MergeSemantics(
              child: Tooltip(
                message: l10n.receiptLanguage,
                child: TextButton.icon(
                  onPressed: reading ? null : onPickLanguage,
                  icon: const Icon(Icons.translate),
                  label: Text(receiptScriptShortName(scan.script),
                      semanticsLabel: receiptScriptName(context, scan.script)),
                ),
              ),
            ),
          ),
          enabled: !reading,
          onTap: onScan,
        ),
      ],
    );
  }
}
