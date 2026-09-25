import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/context_l10n.dart';

/// What went wrong, in full, behind a short on-screen message (issue #118):
/// the error and where it happened, so a problem seen on a phone can be
/// reported without a debugger attached.
class ErrorDetails {
  final Object error;
  final StackTrace? stackTrace;

  ErrorDetails(this.error, [this.stackTrace]);

  /// Records [error] in the debug log too (`flutter run`, `flutter logs`,
  /// Xcode or `adb logcat`), tagged with [where], and returns the details
  /// to show.
  factory ErrorDetails.logged(String where, Object error, [StackTrace? stackTrace]) {
    debugPrint('$where failed: $error${stackTrace == null ? '' : '\n$stackTrace'}');
    return ErrorDetails(error, stackTrace);
  }

  String get text => stackTrace == null ? '$error' : '$error\n\n$stackTrace';
}

/// A short error message in the error color. With [details], it's
/// tappable and says so; a tap shows the full error and stack trace, which
/// can be copied (issue #118).
class ErrorMessage extends StatelessWidget {
  const ErrorMessage(this.message, {super.key, this.details, this.textAlign});

  final String message;
  final ErrorDetails? details;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    final text = Text(message, style: TextStyle(color: color), textAlign: textAlign);
    final details = this.details;
    if (details == null) return text;
    final align = switch (textAlign) {
      TextAlign.center => CrossAxisAlignment.center,
      TextAlign.end || TextAlign.right => CrossAxisAlignment.end,
      _ => CrossAxisAlignment.start,
    };
    return Semantics(
      button: true,
      child: InkWell(
        onTap: () => showErrorDetails(context, details, message: message),
        child: Column(
          crossAxisAlignment: align,
          mainAxisSize: MainAxisSize.min,
          children: [
            text,
            const SizedBox(height: 4),
            Text(
              context.l10n.errorTapForDetails,
              textAlign: textAlign,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                decoration: TextDecoration.underline,
                decorationColor: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The full error and stack trace in a sheet, selectable, with Copy.
Future<void> showErrorDetails(BuildContext context, ErrorDetails details, {String? message}) {
  final all = message == null ? details.text : '$message\n\n${details.text}';
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) {
      final l10n = context.l10n;
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, controller) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(l10n.errorDetailsTitle,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.copy),
                    label: Text(l10n.errorDetailsCopy),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: all));
                      if (!context.mounted) return;
                      ScaffoldMessenger.maybeOf(context)
                          ?.showSnackBar(SnackBar(content: Text(l10n.errorDetailsCopied)));
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  controller: controller,
                  child: SelectableText(
                    all,
                    // 'monospace' is Android's; iOS has Menlo and Courier.
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontFamilyFallback: ['Menlo', 'Courier'],
                        fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
