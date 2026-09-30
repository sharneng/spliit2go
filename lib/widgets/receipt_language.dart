import 'package:flutter/material.dart';

import '../l10n/context_l10n.dart';
import '../services/error_reporting.dart';
import '../services/receipt_scanner.dart';
import 'error_message.dart';

/// The receipt language picker beside Scan receipt (#153): the user says
/// what's printed on the receipt, and the app reads it with that model;
/// nothing is guessed.

/// On the button: short, and the same in every app language.
String receiptScriptShortName(ReceiptScript script) => switch (script) {
      ReceiptScript.latin => 'ABC',
      ReceiptScript.chinese => '中文',
      ReceiptScript.japanese => '日本語',
    };

/// In the list and in messages: each language by its own name.
String receiptScriptName(BuildContext context, ReceiptScript script) => switch (script) {
      ReceiptScript.latin => context.l10n.receiptScriptLatin,
      ReceiptScript.chinese => '中文',
      ReceiptScript.japanese => '日本語',
    };

/// Opens the list of receipt languages. Picking an installed one answers
/// it; picking another downloads it first, and answers it once it's
/// installed. [installed] is refreshed from Google Play services as the
/// list opens, and [onInstalledChanged] hears every change, including a
/// removal, even when nothing is picked.
Future<ReceiptScript?> showReceiptLanguagePicker(
  BuildContext context, {
  required ReceiptScanner scanner,
  required ReceiptScript selected,
  required Set<ReceiptScript> installed,
  required ValueChanged<Set<ReceiptScript>> onInstalledChanged,
}) =>
    showModalBottomSheet<ReceiptScript>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ReceiptLanguageSheet(
        scanner: scanner,
        selected: selected,
        installed: installed,
        onInstalledChanged: onInstalledChanged,
      ),
    );

class _ReceiptLanguageSheet extends StatefulWidget {
  final ReceiptScanner scanner;
  final ReceiptScript selected;
  final Set<ReceiptScript> installed;
  final ValueChanged<Set<ReceiptScript>> onInstalledChanged;

  const _ReceiptLanguageSheet({
    required this.scanner,
    required this.selected,
    required this.installed,
    required this.onInstalledChanged,
  });

  @override
  State<_ReceiptLanguageSheet> createState() => _ReceiptLanguageSheetState();
}

class _ReceiptLanguageSheetState extends State<_ReceiptLanguageSheet> {
  late Set<ReceiptScript> _installed = widget.installed;

  /// Latin once the picked one is removed, as in the form.
  late ReceiptScript _selected = widget.selected;
  final _downloading = <ReceiptScript>{};
  String? _message;
  String? _diagnostics;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _setInstalled(Set<ReceiptScript> installed) {
    if (mounted) {
      setState(() {
        _installed = installed;
        if (!installed.contains(_selected)) _selected = ReceiptScript.latin;
      });
    }
    widget.onInstalledChanged(installed);
  }

  /// Play services is the only record of what's installed.
  Future<void> _refresh() async {
    try {
      _setInstalled(await widget.scanner.installedScripts());
    } catch (e, st) {
      // Best effort: the list as the form last knew it still works.
      if (!isMissingPlugin(e)) ErrorReporter.instance.report(e, st, operation: 'Listing receipt languages');
    }
  }

  void _showError(String message, [String? diagnostics]) => setState(() {
        _message = message;
        _diagnostics = diagnostics;
      });

  Future<void> _download(ReceiptScript script) async {
    setState(() {
      _downloading.add(script);
      _message = null;
    });
    try {
      await widget.scanner.installScript(script);
      _setInstalled({..._installed, script});
      if (mounted) Navigator.of(context).pop(script);
    } on ReceiptTextModelDownloadFailed catch (e) {
      if (!mounted) return;
      _showError(e.offline ? context.l10n.receiptLanguageOffline : context.l10n.receiptLanguageDownloadFailed);
    } catch (e, st) {
      final error = ErrorReporter.instance.report(e, st, operation: 'Downloading a receipt language');
      if (mounted) _showError(context.l10n.receiptLanguageDownloadFailed, error.diagnostics);
    } finally {
      if (mounted) setState(() => _downloading.remove(script));
    }
  }

  Future<void> _remove(ReceiptScript script) async {
    final l10n = context.l10n;
    final name = receiptScriptName(context, script);
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog.adaptive(
        title: Text(l10n.receiptLanguageRemoveTitle(name)),
        content: Text(l10n.receiptLanguageRemoveBody(name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(l10n.commonCancel)),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
              child: Text(l10n.receiptLanguageRemove)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _message = null);
    try {
      await widget.scanner.removeScript(script);
      _setInstalled({..._installed}..remove(script));
    } catch (e, st) {
      final error = ErrorReporter.instance.report(e, st, operation: 'Removing a receipt language');
      if (mounted) _showError(l10n.receiptLanguageRemoveFailed, error.diagnostics);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text(l10n.receiptLanguage, style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(l10n.receiptLanguageIntro, style: theme.textTheme.bodyMedium),
          ),
          for (final script in ReceiptScript.values) _row(context, script),
          if (_message case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: ErrorMessage(message, diagnostics: _diagnostics),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Text(l10n.receiptLanguageNote, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, ReceiptScript script) {
    final l10n = context.l10n;
    final installed = _installed.contains(script);
    final downloading = _downloading.contains(script);
    return ListTile(
      leading: Icon(script == _selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      title: Text(receiptScriptName(context, script)),
      subtitle: Text(downloading
          ? l10n.receiptLanguageDownloading
          : !script.downloadable
              ? l10n.receiptLanguageBuiltIn
              : installed
                  ? l10n.receiptLanguageDownloaded
                  : l10n.receiptLanguageNotDownloaded),
      trailing: downloading
          ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : !script.downloadable
              ? null
              : installed
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: l10n.receiptLanguageRemove,
                      onPressed: () => _remove(script),
                    )
                  : IconButton(
                      icon: const Icon(Icons.download_outlined),
                      tooltip: l10n.receiptLanguageDownload,
                      onPressed: () => _download(script),
                    ),
      onTap: downloading
          ? null
          : installed
              ? () => Navigator.of(context).pop(script)
              : () => _download(script),
    );
  }
}
