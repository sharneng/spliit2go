import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/main.dart';
import 'package:spliit2go/theme.dart';

void main() {
  // Regression test for the "deep black nav bar regardless of theme"
  // report on issue #24: on a device targeting Android API 35+,
  // Window.setNavigationBarColor (what AnnotatedRegion<SystemUiOverlayStyle>
  // turns into) is a documented no-op, so the fix that actually matters
  // is painting Flutter-side content -- a Container in the current
  // theme's own scaffoldBackgroundColor -- behind the now-always-
  // transparent system bar, rather than trying to recolor the bar
  // itself. This test can't see the real system bar (that needs a
  // device), but it can confirm the backdrop is really there and really
  // tracks the active theme, which is what would have caught this
  // regression before it shipped.
  testWidgets('paints a full-bleed backdrop in the active theme\'s own background color',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: spliit2goLightTheme,
      builder: spliit2goAppBuilder,
      home: const Scaffold(body: Text('content')),
    ));

    final container = tester.widget<Container>(find.byType(Container).first);
    expect(container.color, spliit2goLightTheme.scaffoldBackgroundColor);
  });

  testWidgets('the backdrop tracks dark mode too, not just the light theme',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: spliit2goLightTheme,
      darkTheme: spliit2goDarkTheme,
      themeMode: ThemeMode.dark,
      builder: spliit2goAppBuilder,
      home: const Scaffold(body: Text('content')),
    ));

    final container = tester.widget<Container>(find.byType(Container).first);
    expect(container.color, spliit2goDarkTheme.scaffoldBackgroundColor);
  });

  testWidgets('the backdrop sits behind a SafeArea that insets the bottom only',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: spliit2goLightTheme,
      builder: spliit2goAppBuilder,
      home: const Scaffold(body: Text('content')),
    ));

    final safeArea = tester.widget<SafeArea>(find.byType(SafeArea).first);
    expect(safeArea.top, isFalse);
    expect(safeArea.bottom, isTrue);
  });
}
