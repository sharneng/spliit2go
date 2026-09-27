import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_locales.dart';
import '../l10n/context_l10n.dart';
import '../services/app_settings.dart';
import '../services/error_reporting.dart';
import '../services/receipt_cache.dart';
import '../services/receipt_downloader.dart';
import '../services/settings_service.dart';
import '../utils/byte_size.dart';
import '../widgets/error_message.dart';

/// App-wide preferences, separate from an individual group's settings.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key, this.receipts});

  /// The receipts stored on this device, for the Storage section (#123).
  /// Without it, the section isn't shown.
  final ReceiptCache? receipts;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsScope.of(context);
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          _sectionHeading(context, l10n.appSettingsTheme),
          for (final option in [
            (ThemeMode.light, l10n.appSettingsThemeLight),
            (ThemeMode.dark, l10n.appSettingsThemeDark),
            (ThemeMode.system, l10n.appSettingsThemeSystem),
          ])
            _optionTile(
              context,
              settings: settings,
              label: option.$2,
              selected: settings.themeMode == option.$1,
              onSelected: () => settings.setThemeMode(option.$1),
            ),
          const Divider(height: 32),
          // Issue #51: explicit language override. "System default" first
          // (clears the override); the language names are each language's
          // own name for itself, deliberately untranslated, so the list
          // stays findable from any UI language.
          _sectionHeading(context, l10n.appSettingsLanguage),
          _optionTile(
            context,
            settings: settings,
            label: l10n.appSettingsLanguageSystem,
            selected: settings.locale == null,
            onSelected: () => settings.setLocale(null),
          ),
          for (final option in appLocaleOptions)
            _optionTile(
              context,
              settings: settings,
              label: option.nativeName,
              selected: settings.locale == option.locale,
              onSelected: () => settings.setLocale(option.locale),
            ),
          if (receipts case final receipts?) ...[
            const Divider(height: 32),
            _sectionHeading(context, l10n.appSettingsStorage),
            _ReceiptStorageTile(receipts),
            _ReceiptDownloadSettings(receipts),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  /// One selectable row: runs [onSelected] and, if persisting the choice
  /// fails (the setting reverts itself before rethrowing), tells the user.
  Widget _optionTile(
    BuildContext context, {
    required AppSettings settings,
    required String label,
    required bool selected,
    required Future<void> Function() onSelected,
  }) =>
      ListTile(
        title: Text(label),
        selected: selected,
        trailing: selected ? const Icon(Icons.check) : null,
        enabled: !settings.saving,
        onTap: () async {
          try {
            await onSelected();
          } catch (e, st) {
            // Saving a setting to the device's storage has no expected
            // failure: logged, with details (#119 review).
            final error = ErrorReporter.instance.report(e, st, operation: 'Saving an app setting');
            if (!context.mounted) return;
            showErrorSnackBar(context, context.l10n.appSettingsSaveError,
                diagnostics: error.diagnostics);
          }
        },
      );
}

/// How much space stored receipts use, with Clear (#123). They're only
/// copies: Clear removes them from this device, and they download again
/// when opened.
class _ReceiptStorageTile extends StatefulWidget {
  const _ReceiptStorageTile(this.receipts);
  final ReceiptCache receipts;

  @override
  State<_ReceiptStorageTile> createState() => _ReceiptStorageTileState();
}

class _ReceiptStorageTileState extends State<_ReceiptStorageTile> {
  int? _bytes;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    try {
      final bytes = await widget.receipts.usage();
      if (mounted) setState(() => _bytes = bytes);
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Measuring stored receipts');
    }
  }

  Future<void> _clear() async {
    final l10n = context.l10n;
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog.adaptive(
        title: Text(l10n.appSettingsReceiptsClearTitle),
        content: Text(l10n.appSettingsReceiptsClearBody),
        actions: _confirmActions(dialogContext),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    final downloads = ReceiptDownloader.of(widget.receipts.db);
    try {
      // Favorite groups' downloads stop, and start again only at their
      // next refresh (#127).
      downloads.cancelAll();
      await widget.receipts.clear();
      await downloads.refreshAll();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(context.l10n.appSettingsReceiptsCleared)));
    } catch (e, st) {
      // Deleting this app's own files has no expected failure (#119).
      final error = ErrorReporter.instance.report(e, st, operation: 'Clearing stored receipts');
      if (mounted) {
        showErrorSnackBar(context, context.l10n.appSettingsReceiptsClearFailed,
            diagnostics: error.diagnostics);
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
      await _measure();
    }
  }

  /// Cancel and a destructive Clear, as the group list's Remove asks.
  List<Widget> _confirmActions(BuildContext dialogContext) {
    final l10n = dialogContext.l10n;
    final platform = Theme.of(dialogContext).platform;
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
      return [
        CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false), child: Text(l10n.commonCancel)),
        CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.appSettingsReceiptsClear)),
      ];
    }
    return [
      TextButton(
          onPressed: () => Navigator.pop(dialogContext, false), child: Text(l10n.commonCancel)),
      TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
          child: Text(l10n.appSettingsReceiptsClear)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bytes = _bytes;
    return ListTile(
      title: Text(l10n.appSettingsReceipts),
      subtitle: Text(bytes == null
          ? ''
          : bytes == 0
              ? l10n.appSettingsReceiptsNone
              : formatByteSize(context, bytes)),
      trailing: TextButton(
        onPressed: bytes == null || bytes == 0 || _clearing ? null : _clear,
        child: Text(l10n.appSettingsReceiptsClear),
      ),
    );
  }
}

/// Downloading favorite groups' receipts ahead, and the limit on what
/// receipts may take (#127).
class _ReceiptDownloadSettings extends StatefulWidget {
  const _ReceiptDownloadSettings(this.receipts);
  final ReceiptCache receipts;

  @override
  State<_ReceiptDownloadSettings> createState() => _ReceiptDownloadSettingsState();
}

class _ReceiptDownloadSettingsState extends State<_ReceiptDownloadSettings> {
  final _settings = SettingsService();
  ReceiptDownloadMode? _mode;
  int? _limitMb;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final mode = await _settings.receiptDownloadMode();
      final limit = await _settings.receiptStorageLimitMb();
      if (!mounted) return;
      setState(() {
        _mode = mode;
        _limitMb = limit;
      });
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Reading the receipt settings');
    }
  }

  String _modeLabel(ReceiptDownloadMode mode) => switch (mode) {
        ReceiptDownloadMode.off => context.l10n.appSettingsReceiptDownloadsOff,
        ReceiptDownloadMode.wifiOnly => context.l10n.appSettingsReceiptDownloadsWifiOnly,
        ReceiptDownloadMode.always => context.l10n.appSettingsReceiptDownloadsAlways,
      };

  String _limitLabel(int mb) => context.l10n
      .bytesMegabytes(NumberFormat.decimalPattern(context.appLocale.toString()).format(mb));

  Future<T?> _choose<T>(String title, List<(T, String)> options, T current) =>
      showDialog<T>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: Text(title),
          children: [
            for (final (value, label) in options)
              ListTile(
                title: Text(label),
                trailing: value == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(dialogContext, value),
              ),
          ],
        ),
      );

  Future<void> _save(Future<void> Function() save) async {
    try {
      await save();
    } catch (e, st) {
      final error = ErrorReporter.instance.report(e, st, operation: 'Saving an app setting');
      if (mounted) {
        showErrorSnackBar(context, context.l10n.appSettingsSaveError,
            diagnostics: error.diagnostics);
      }
    }
    await _load();
  }

  Future<void> _chooseMode() async {
    final current = _mode;
    if (current == null) return;
    final mode = await _choose(context.l10n.appSettingsReceiptDownloads,
        [for (final m in ReceiptDownloadMode.values) (m, _modeLabel(m))], current);
    if (mode == null || mode == current) return;
    await _save(() async {
      await _settings.setReceiptDownloadMode(mode);
      final downloads = ReceiptDownloader.of(widget.receipts.db);
      // Turned off, or narrowed to Wi-Fi: what's running stops, and the
      // next refresh starts again under the new setting.
      downloads.cancelAll();
      await downloads.refreshAll();
    });
  }

  Future<void> _chooseLimit() async {
    final current = _limitMb;
    if (current == null) return;
    final mb = await _choose(context.l10n.appSettingsReceiptLimit,
        [for (final c in receiptStorageLimitChoicesMb) (c, _limitLabel(c))], current);
    if (mb == null || mb == current) return;
    await _save(() async {
      await _settings.setReceiptStorageLimitMb(mb);
      widget.receipts.limit = mb * 1024 * 1024;
      // A lower limit: the viewing cache makes room now.
      await widget.receipts.makeRoom(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mode = _mode, limit = _limitMb;
    return Column(children: [
      ListTile(
        title: Text(l10n.appSettingsReceiptDownloads),
        subtitle: Text(mode == null
            ? l10n.appSettingsReceiptDownloadsHint
            : '${_modeLabel(mode)} · ${l10n.appSettingsReceiptDownloadsHint}'),
        onTap: mode == null ? null : _chooseMode,
      ),
      ListTile(
        title: Text(l10n.appSettingsReceiptLimit),
        subtitle: limit == null ? null : Text(_limitLabel(limit)),
        onTap: limit == null ? null : _chooseLimit,
      ),
    ]);
  }
}
