import 'package:flutter/material.dart';

import '../l10n/app_locales.dart';
import '../l10n/context_l10n.dart';
import '../services/app_settings.dart';
import '../services/error_reporting.dart';
import '../widgets/error_message.dart';

/// App-wide preferences, separate from an individual group's settings.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key});

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
