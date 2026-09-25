import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/context_l10n.dart';
import '../services/error_reporting.dart';

/// The message a screen shows for [error] (issue #118, #119 review): a
/// connection failure always reads the same ("check your connection");
/// a user error gets the screen's specific guidance ([userMessage]); and
/// anything unexpected gets the screen's short [unexpected] message, never
/// the raw exception text, which lives in the diagnostics instead.
String errorMessageFor(
  BuildContext context,
  ReportedError error, {
  required String unexpected,
  String? Function(Object error)? userMessage,
}) =>
    switch (error.kind) {
      ErrorKind.connection => context.l10n.errorConnection,
      ErrorKind.user => userMessage?.call(error.error) ?? unexpected,
      ErrorKind.unexpected => unexpected,
    };

/// A short error message in the error color. With [diagnostics] (only
/// unexpected errors have them), it's tappable and says so; a tap shows
/// the message and diagnostics, which can be copied. Presentation only:
/// what's shown and whether there are details is decided by
/// [ErrorReporter] and the screen.
class ErrorMessage extends StatelessWidget {
  const ErrorMessage(this.message, {super.key, this.diagnostics, this.textAlign});

  final String message;
  final String? diagnostics;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    final diagnostics = this.diagnostics;
    // Selectable when there's nothing behind it, so a message that carries
    // something to copy (a created group's link, #116) still can be.
    if (diagnostics == null) {
      return SelectableText(message, style: TextStyle(color: color), textAlign: textAlign);
    }
    final align = switch (textAlign) {
      TextAlign.center => CrossAxisAlignment.center,
      TextAlign.end || TextAlign.right => CrossAxisAlignment.end,
      _ => CrossAxisAlignment.start,
    };
    return Semantics(
      button: true,
      child: InkWell(
        onTap: () => showErrorDetails(context, diagnostics, message: message),
        child: Column(
          crossAxisAlignment: align,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, style: TextStyle(color: color), textAlign: textAlign),
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

/// A snack bar for an error that has no place on the screen itself, with a
/// Details action when the error is unexpected.
/// The snack bar outlives a screen that closes right after showing it
/// (the expense form, #119 review), so Details then opens the sheet from
/// the navigator the screen was in.
void showErrorSnackBar(BuildContext context, String message, {String? diagnostics}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final navigator = Navigator.maybeOf(context);
  messenger.showSnackBar(SnackBar(
    content: Text(message),
    action: diagnostics == null
        ? null
        : SnackBarAction(
            label: context.l10n.errorDetailsAction,
            onPressed: () {
              final sheetContext =
                  context.mounted ? context : navigator?.overlay?.context;
              if (sheetContext == null || !sheetContext.mounted) return;
              showErrorDetails(sheetContext, diagnostics, message: message);
            },
          ),
  ));
}

/// The message and diagnostics in a sheet, selectable, with Copy.
Future<void> showErrorDetails(BuildContext context, String diagnostics, {String? message}) {
  final all = message == null ? diagnostics : '$message\n\n$diagnostics';
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

/// Shows errors nothing caught (see [installErrorHandlers]) as a snack
/// bar with Details, after the frame they happened in, so a failure during
/// a build isn't followed by another UI change inside that same build.
/// Sits in MaterialApp.builder: under the ScaffoldMessenger, over the
/// Navigator ([navigatorKey] gives the sheet a context inside it).
class UncaughtErrorPresenter extends StatefulWidget {
  const UncaughtErrorPresenter({
    super.key,
    required this.reporter,
    required this.navigatorKey,
    required this.child,
  });

  final ErrorReporter reporter;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<UncaughtErrorPresenter> createState() => _UncaughtErrorPresenterState();
}

class _UncaughtErrorPresenterState extends State<UncaughtErrorPresenter> {
  @override
  void initState() {
    super.initState();
    widget.reporter.uncaught.addListener(_onUncaught);
  }

  @override
  void dispose() {
    widget.reporter.uncaught.removeListener(_onUncaught);
    super.dispose();
  }

  void _onUncaught() {
    final error = widget.reporter.uncaught.value;
    if (error == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l10n = context.l10n;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(l10n.errorUnexpected),
        action: SnackBarAction(
          label: l10n.errorDetailsAction,
          onPressed: () {
            final sheetContext = widget.navigatorKey.currentState?.overlay?.context;
            if (sheetContext != null) {
              showErrorDetails(sheetContext, error.diagnostics!, message: l10n.errorUnexpected);
            }
          },
        ),
      ));
    });
    // A frame may not be coming on its own.
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
