import 'package:flutter/material.dart';

/// spliit2go's light theme -- Material 3, seeded from [Colors.teal].
/// Paired with [spliit2goDarkTheme] below so the app actually has
/// something to switch to when the system is in dark mode (issue #25;
/// see the doc comment on [Spliit2GoApp]'s `MaterialApp` for why a
/// `darkTheme` was the whole bug).
ThemeData get spliit2goLightTheme => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.light,
    );

/// spliit2go's dark theme -- same Material 3 + teal seed as
/// [spliit2goLightTheme], opposite [Brightness.dark], so system dark
/// mode gets a genuinely dark version of this app's own look rather
/// than a generic Material dark theme.
ThemeData get spliit2goDarkTheme => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
    );
