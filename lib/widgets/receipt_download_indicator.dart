import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import '../l10n/context_l10n.dart';
import '../theme.dart';
import '../utils/spoken.dart';
import '../services/receipt_downloader.dart';
import 'caption_icon.dart';
import 'error_message.dart';

/// A favorite group's 📎 (#127, Kenneth): blinking while its receipts
/// download, red after an error, solid once they're all on this device,
/// and struck through while some aren't and nothing is wrong (waiting for
/// Wi-Fi, or for the next refresh after Clear). Nothing for other groups.
/// Tapping it shows the progress, with Retry. The diagonal clip of the
/// expense rows' receipts mark, so the app has one clip (#209).
///
/// In an app bar it's an icon button. In a group row ([row] given) it's
/// only the drawing, sized from the row's text so it grows with the text
/// size, and the row lays a [ReceiptDownloadTapArea] over it: a target
/// larger than the clip's box that doesn't make the row any taller (#209).
class ReceiptDownloadIndicator extends StatelessWidget {
  const ReceiptDownloadIndicator({
    super.key,
    required this.status,
    required this.onRetry,
    this.size = 24,
    this.row,
    this.maxRowSize = double.infinity,
  });

  final ValueListenable<ReceiptDownloadStatus> status;
  final VoidCallback onRetry;

  /// In an app bar. A row's clip is sized from its text instead.
  final double size;

  /// Ties a row's clip to its [ReceiptDownloadTapArea].
  final ReceiptRowClip? row;

  /// How large a row's clip may grow, so the title beside it isn't broken
  /// mid-word; never below its size at the usual text size.
  final double maxRowSize;

  /// On the 📎 while it blinks.
  @visibleForTesting
  static const blinking = ValueKey('receipt-downloads-blinking');

  /// On the 📎 while it's struck through, waiting.
  @visibleForTesting
  static const struckThrough = ValueKey('receipt-downloads-struck-through');

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: status,
        builder: (context, s, _) {
          if (!s.shown) return const SizedBox.shrink();
          final row = this.row;
          if (row == null) {
            return MergeSemantics(
              child: Semantics(
                value: _spokenState(context, s),
                child: IconButton(
                  tooltip: context.l10n.receiptDownloadsTooltip,
                  onPressed: () => _showDetails(context, status, onRetry),
                  icon: _clip(context, s, size),
                ),
              ),
            );
          }
          // The expense rows' marks' size, growing with the text (#209).
          final rowSize =
              titleMarkSize(context).clamp(0.0, maxRowSize.clamp(titleMarkBaseSize, double.infinity));
          // Told to the tap area after this frame, so its target follows
          // the clip as drawn, capped or not (#212 review).
          if (row.size.value != rowSize) {
            SchedulerBinding.instance.addPostFrameCallback((_) => row.size.value = rowSize);
          }
          // Centered over the participants icon below rather than ending
          // where it does: the diagonal clip ending flush looked off to the
          // right (Kenneth on a device, #211). Both Lucide drawings sit centered
          // in their boxes, so the boxes' centers are lined up.
          final nudge = -(captionIconSize(context, captionFontSize: _captionFontSize(context)) -
                  rowSize) /
              2;
          return Transform.translate(
            offset: Offset(Directionality.of(context) == TextDirection.rtl ? -nudge : nudge, 0),
            child: CompositedTransformTarget(
              link: row.link,
              // Read out by the tap area laid over it.
              child: ExcludeSemantics(child: _clip(context, s, rowSize)),
            ),
          );
        },
      );

  // The caption (the row's subtitle) is bodyMedium, as ListTile draws it.
  static double? _captionFontSize(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium?.fontSize;

  Widget _clip(BuildContext context, ReceiptDownloadStatus s, double size) {
    final theme = Theme.of(context);
    // Red: an error. Otherwise the clip's own color (dimmed in a row, like
    // its other marks), struck through while some aren't here and nothing
    // is wrong: waiting for Wi-Fi, or for the next refresh (#211).
    final color = s.isError
        ? theme.colorScheme.error
        : row == null
            ? null
            : theme.colorScheme.secondaryContent;
    final waiting = !s.isError && !s.complete && !s.running;
    final clip = Icon(LucideIcons.paperclip, size: size, color: color);
    final icon = waiting
        // Built where the clip is, so the strike takes the icon color the
        // app bar's button gives it.
        ? Builder(key: struckThrough, builder: (context) {
            final resolved =
                color ?? IconTheme.of(context).color ?? theme.colorScheme.onSurfaceVariant;
            // Drawn opaque and dimmed together, so the crossings aren't
            // darker than the rest.
            return Opacity(
              opacity: resolved.a,
              child: CustomPaint(
                  foregroundPainter: _StrikeThrough(resolved.withValues(alpha: 1)),
                  child: Icon(LucideIcons.paperclip,
                      size: size, color: resolved.withValues(alpha: 1))),
            );
          })
        : clip;
    return s.running ? _Blinking(key: blinking, child: icon) : icon;
  }
}

/// What ties a group row's clip to its tap area: where the clip is drawn
/// and how large.
class ReceiptRowClip {
  final link = LayerLink();

  /// The clip's size as drawn; null until it has been.
  final size = ValueNotifier<double?>(null);
}

/// A row's 📎 as a button: a target a [margin] larger than the clip all
/// round, centered on the [ReceiptDownloadIndicator] of the same [row],
/// which reaches past the clip's own box, so the row keeps its height
/// (#209, #211). Goes in a [Stack] over the whole row; nothing while the
/// clip isn't shown.
class ReceiptDownloadTapArea extends StatelessWidget {
  const ReceiptDownloadTapArea(
      {super.key, required this.row, required this.status, required this.onRetry});

  final ReceiptRowClip row;
  final ValueListenable<ReceiptDownloadStatus> status;
  final VoidCallback onRetry;

  /// How far the target reaches past the clip on each side. Apple's 44
  /// points reached into the name and the count and caught taps meant to
  /// open the group (Kenneth on a device, #211), so it's a margin around the
  /// clip instead, growing with it. The group screen's app bar has the
  /// full-size button.
  static const margin = 7.0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([status, row.size]),
        builder: (context, _) {
          final s = status.value;
          final clipSize = row.size.value;
          if (!s.shown || clipSize == null) return const SizedBox.shrink();
          final label = context.l10n.receiptDownloadsTooltip;
          final extent = clipSize + 2 * margin;
          return CompositedTransformFollower(
            link: row.link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.center,
            followerAnchor: Alignment.center,
            child: Semantics(
              button: true,
              label: label,
              value: _spokenState(context, s),
              excludeSemantics: true,
              child: Tooltip(
                message: label,
                child: InkResponse(
                  radius: extent / 2,
                  onTap: () => _showDetails(context, status, onRetry),
                  child: SizedBox.square(dimension: extent),
                ),
              ),
            ),
          );
        },
      );
}

/// What the clip says after its name: the details sheet's headline and
/// what's holding it up, if anything ("2 of 5 receipts available offline.
/// Waiting for Wi-Fi…"), so the state isn't only its color (#209).
String _spokenState(BuildContext context, ReceiptDownloadStatus s) {
  final l10n = context.l10n;
  final reason = _reason(l10n, s);
  return spokenSentences([_headline(l10n, s), if (reason != null) reason], l10n.spokenSentenceEnd);
}

String _headline(AppLocalizations l10n, ReceiptDownloadStatus s) => s.running
    ? l10n.receiptDownloadsRunning(s.available, s.total)
    : s.complete
        ? l10n.receiptDownloadsComplete
        : s.unverified
            ? l10n.receiptDownloadsUnverified
            : l10n.receiptDownloadsPartial(s.available, s.total);

String? _reason(AppLocalizations l10n, ReceiptDownloadStatus s) => s.running || s.complete
    ? null
    : switch (s.problem) {
        ReceiptDownloadProblem.waitingForWifi => l10n.receiptDownloadsWaitingForWifi,
        ReceiptDownloadProblem.offline => l10n.receiptDownloadsOffline,
        ReceiptDownloadProblem.noSpace => l10n.receiptDownloadsNoSpace,
        ReceiptDownloadProblem.failed => l10n.receiptDownloadsFailed,
        null => null,
      };

Future<void> _showDetails(BuildContext context, ValueListenable<ReceiptDownloadStatus> status,
        VoidCallback onRetry) =>
    showModalBottomSheet<void>(
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

class _Details extends StatelessWidget {
  const _Details({required this.status, required this.onRetry});
  final ReceiptDownloadStatus status;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final s = status;
    final headline = _headline(l10n, s);
    final reason = _reason(l10n, s);
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

/// The waiting 📎's strike: the opposite diagonal to the clip's, top-left
/// to bottom-right, in the clip's own color and Lucide's stroke width.
class _StrikeThrough extends CustomPainter {
  const _StrikeThrough(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide / 24;
    canvas.drawLine(
        Offset(4 * unit, 4 * unit),
        Offset(20 * unit, 20 * unit),
        Paint()
          ..color = color
          ..strokeWidth = 2 * unit
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_StrikeThrough old) => old.color != color;
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
