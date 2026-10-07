import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import '../l10n/context_l10n.dart';
import '../utils/spoken.dart';
import '../services/receipt_downloader.dart';
import 'caption_icon.dart';
import 'error_message.dart';

/// A favorite group's 📎 (#127, Kenneth): blinking while its receipts
/// download, red after an error, solid once they're all on this device,
/// and dimmed while some aren't and nothing is wrong (waiting for Wi-Fi,
/// or for the next refresh after Clear). Nothing for other groups.
/// Tapping it shows the progress, with Retry. The diagonal clip of the
/// expense rows' receipts mark, so the app has one clip (#209).
///
/// In an app bar it's an icon button. In a group row ([link] given) it's
/// only the drawing, sized from the row's text so it grows with the text
/// size, and the row lays a [ReceiptDownloadTapArea] over it: a full-size
/// target that doesn't make the row any taller (#209).
class ReceiptDownloadIndicator extends StatelessWidget {
  const ReceiptDownloadIndicator({
    super.key,
    required this.status,
    required this.onRetry,
    this.size = 24,
    this.link,
    this.maxRowSize = double.infinity,
  });

  final ValueListenable<ReceiptDownloadStatus> status;
  final VoidCallback onRetry;

  /// In an app bar. A row's clip is sized from its text instead.
  final double size;

  /// Ties a row's clip to its [ReceiptDownloadTapArea].
  final LayerLink? link;

  /// How large a row's clip may grow, so the title beside it isn't broken
  /// mid-word; never below its size at the usual text size.
  final double maxRowSize;

  /// On the 📎 while it blinks.
  @visibleForTesting
  static const blinking = ValueKey('receipt-downloads-blinking');

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: status,
        builder: (context, s, _) {
          if (!s.shown) return const SizedBox.shrink();
          final link = this.link;
          if (link == null) {
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
          // Sized like a caption icon, from the title's text (#209).
          final rowSize = rowClipSize(context).clamp(0.0, maxRowSize.clamp(_baseRowSize(context), double.infinity));
          // The clip's ink stops short of its box's end; nudged out so it
          // ends where the participants icon below does (#201 review).
          final nudge = rowSize * _clipInkGap -
              captionIconSize(context, captionFontSize: _captionFontSize(context)) *
                  _participantsInkGap;
          return Transform.translate(
            offset: Offset(Directionality.of(context) == TextDirection.rtl ? -nudge : nudge, 0),
            child: CompositedTransformTarget(
              link: link,
              // Read out by the tap area laid over it.
              child: ExcludeSemantics(child: _clip(context, s, rowSize)),
            ),
          );
        },
      );

  /// A row's clip: a caption icon's size for the row's title text.
  static double rowClipSize(BuildContext context) => captionIconSize(context);

  /// A row's clip at the usual text size.
  static double _baseRowSize(BuildContext context) =>
      (DefaultTextStyle.of(context).style.fontSize ?? 14) * 1.15;

  // The caption (the row's subtitle) is bodyMedium, as ListTile draws it.
  static double? _captionFontSize(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium?.fontSize;

  // How far the ink stops short of the box's end, per point of size, from
  // the Lucide drawings: the paperclip ends at 21.2 of 24, the users icon
  // at 23.
  static const _clipInkGap = 2.8 / 24;
  static const _participantsInkGap = 1 / 24;

  Widget _clip(BuildContext context, ReceiptDownloadStatus s, double size) {
    final theme = Theme.of(context);
    // Red: an error. Solid: all here. Dimmed: not all here, and nothing
    // wrong (waiting for Wi-Fi, or for the next refresh).
    final color = s.isError
        ? theme.colorScheme.error
        : s.complete || s.running
            ? null
            : theme.disabledColor;
    final icon = Icon(LucideIcons.paperclip, size: size, color: color);
    return s.running ? _Blinking(key: blinking, child: icon) : icon;
  }
}

/// A row's 📎 as a button: a full-size target centered on the
/// [ReceiptDownloadIndicator] it's [link]ed to, which reaches past the
/// clip's own small box, so the row keeps its height (#209). Goes in a
/// [Stack] over the whole row; nothing while the clip isn't shown.
class ReceiptDownloadTapArea extends StatelessWidget {
  const ReceiptDownloadTapArea(
      {super.key, required this.link, required this.status, required this.onRetry});

  final LayerLink link;
  final ValueListenable<ReceiptDownloadStatus> status;
  final VoidCallback onRetry;

  /// The smallest target Apple's guidelines allow.
  static const extent = 44.0;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: status,
        builder: (context, s, _) {
          if (!s.shown) return const SizedBox.shrink();
          final label = context.l10n.receiptDownloadsTooltip;
          return CompositedTransformFollower(
            link: link,
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
                  child: const SizedBox.square(dimension: extent),
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
