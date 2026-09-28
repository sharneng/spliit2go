import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../l10n/context_l10n.dart';
import '../services/receipt_downloader.dart';
import 'error_message.dart';

/// A favorite group's 📎 (#127, Kenneth): blinking while its receipts
/// download, red after an error, solid once they're all on this device,
/// and dimmed while some aren't and nothing is wrong (waiting for Wi-Fi,
/// or for the next refresh after Clear). Nothing for other groups.
/// Tapping it shows the progress, with Retry.
class ReceiptDownloadIndicator extends StatelessWidget {
  const ReceiptDownloadIndicator({
    super.key,
    required this.status,
    required this.onRetry,
    this.size = 24,
    this.compact = false,
  });

  final ValueListenable<ReceiptDownloadStatus> status;
  final VoidCallback onRetry;
  final double size;

  /// Beside a title, not in an app bar: no extra height.
  final bool compact;

  /// On the 📎 while it blinks.
  @visibleForTesting
  static const blinking = ValueKey('receipt-downloads-blinking');

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: status,
        builder: (context, s, _) {
          if (!s.shown) return const SizedBox.shrink();
          final l10n = context.l10n;
          final theme = Theme.of(context);
          // Red: an error. Solid: all here. Dimmed: not all here, and
          // nothing wrong (waiting for Wi-Fi, or for the next refresh).
          final color = s.isError
              ? theme.colorScheme.error
              : s.complete || s.running
                  ? null
                  : theme.disabledColor;
          final icon = Icon(Icons.attach_file, size: size, color: color);
          return IconButton(
            tooltip: l10n.receiptDownloadsTooltip,
            // Small in the group list, so the row keeps its height.
            constraints: compact ? const BoxConstraints() : null,
            padding: compact ? const EdgeInsets.symmetric(horizontal: 6) : null,
            style: compact
                ? const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap)
                : null,
            visualDensity: VisualDensity.compact,
            onPressed: () => _showDetails(context),
            icon: s.running ? _Blinking(key: blinking, child: icon) : icon,
          );
        },
      );

  Future<void> _showDetails(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            // Full width however short the text: a sheet sizes to its child.
            child: ValueListenableBuilder(
              valueListenable: status,
              builder: (context, s, _) => _Details(
                status: s,
                onRetry: () {
                  Navigator.pop(sheetContext);
                  onRetry();
                },
              ),
            ),
          ),
        ),
      );
}

class _Details extends StatelessWidget {
  const _Details({required this.status, required this.onRetry});
  final ReceiptDownloadStatus status;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final s = status;
    final headline = s.running
        ? l10n.receiptDownloadsRunning(s.available, s.total)
        : s.complete
            ? l10n.receiptDownloadsComplete
            : s.unverified
                ? l10n.receiptDownloadsUnverified
                : l10n.receiptDownloadsPartial(s.available, s.total);
    final reason = s.running || s.complete
        ? null
        : switch (s.problem) {
            ReceiptDownloadProblem.waitingForWifi => l10n.receiptDownloadsWaitingForWifi,
            ReceiptDownloadProblem.offline => l10n.receiptDownloadsOffline,
            ReceiptDownloadProblem.noSpace => l10n.receiptDownloadsNoSpace,
            ReceiptDownloadProblem.failed => l10n.receiptDownloadsFailed,
            null => null,
          };
    return SizedBox(
      width: double.infinity,
      child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.receiptDownloadsTooltip, style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        Text(headline),
        if (s.running) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: s.total == 0 ? null : s.available / s.total),
        ],
        if (reason != null) ...[
          const SizedBox(height: 8),
          s.isError
              ? ErrorMessage(reason, diagnostics: s.diagnostics)
              : Text(reason, style: theme.textTheme.bodyMedium),
        ],
        if (!s.running && !s.complete) ...[
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.commonRetry),
          ),
        ],
      ],
      ),
    );
  }
}

/// Fades its child in and out while mounted.
class _Blinking extends StatefulWidget {
  const _Blinking({super.key, required this.child});
  final Widget child;

  @override
  State<_Blinking> createState() => _BlinkingState();
}

class _BlinkingState extends State<_Blinking> with SingleTickerProviderStateMixin {
  late final _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween<double>(begin: 1, end: 0.25).animate(_controller),
        child: widget.child,
      );
}
