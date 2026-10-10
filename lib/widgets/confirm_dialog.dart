import 'package:flutter/cupertino.dart' show CupertinoDialogAction;
import 'package:flutter/material.dart';

import '../l10n/context_l10n.dart';

/// Asks [title], with the [message]'s paragraphs under it: true when
/// [action] is chosen, false when it's cancelled or dismissed. With no
/// [action], a lone [cancel] closes it, an "OK" for a dialog that only
/// tells. [cancel] is "Cancel" unless given.
///
/// Every alert in the app is one of these (#276), in the style settled on
/// for #272's:
/// - On an iPhone, the system's own buttons, which Material's are a size
///   smaller than: Cancel (or a lone OK) semibold, as UIKit draws it, and
///   a [destructive] action in the system red. On Android, Material's,
///   a [destructive] action in the error color.
/// - The message left-aligned, in the primary text color (grey was too
///   hard to read this much in), at 15pt on an iPhone (as iOS 26) and
///   Material's size on Android, with a small gap above each paragraph.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  List<String> message = const [],
  String? action,
  bool destructive = false,
  String? cancel,
}) async =>
    await showAdaptiveDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final cancelLabel = cancel ?? dialogContext.l10n.commonCancel;
        final cupertino = _cupertino(dialogContext);
        return AlertDialog.adaptive(
          title: Text(title),
          content: message.isEmpty ? null : DialogMessage(message),
          actions: cupertino
              ? [
                  CupertinoDialogAction(
                      isDefaultAction: true,
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(cancelLabel)),
                  if (action != null)
                    CupertinoDialogAction(
                        isDestructiveAction: destructive,
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: Text(action)),
                ]
              : [
                  TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(cancelLabel)),
                  if (action != null)
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        style: destructive
                            ? TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error)
                            : null,
                        child: Text(action)),
                ],
        );
      },
    ) ??
    false;

bool _cupertino(BuildContext context) =>
    const {TargetPlatform.iOS, TargetPlatform.macOS}.contains(Theme.of(context).platform);

/// An alert's message: left-aligned paragraphs, each with a small gap
/// above (Kenneth, #272: not justified, which gaps the words on a
/// dialog's short lines).
class DialogMessage extends StatelessWidget {
  const DialogMessage(this.paragraphs, {super.key});

  final List<String> paragraphs;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final paragraph in paragraphs)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(paragraph,
                  textAlign: TextAlign.start,
                  style: TextStyle(
                      fontSize: _cupertino(context) ? 15 : null, color: Theme.of(context).colorScheme.onSurface)),
            ),
        ],
      );
}
