import 'package:flutter/material.dart';

import '../l10n/context_l10n.dart';
import '../services/app_settings.dart';

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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(l10n.appSettingsTheme,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final option in [
            (ThemeMode.light, l10n.appSettingsThemeLight),
            (ThemeMode.dark, l10n.appSettingsThemeDark),
            (ThemeMode.system, l10n.appSettingsThemeSystem),
          ])
            ListTile(
              title: Text(option.$2),
              selected: settings.themeMode == option.$1,
              trailing: settings.themeMode == option.$1
                  ? const Icon(Icons.check)
                  : null,
              enabled: !settings.saving,
              onTap: () async {
                try {
                  await settings.setThemeMode(option.$1);
                } catch (_) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.appSettingsSaveError)),
                  );
                }
              },
            ),
        ],
      ),
    );
  }
}
