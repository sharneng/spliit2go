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

  testWidgets('the backdrop sits behind a SafeArea that insets the sides only (#197)',
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
    expect(safeArea.left, isTrue);
    expect(safeArea.right, isTrue);
    // Content runs to the bottom edge; each screen keeps its last row
    // above the gesture bar itself.
    expect(safeArea.bottom, isFalse);
  });

  testWidgets("a sheet's barrier dims the bottom strip too (#190)", (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: spliit2goLightTheme,
      builder: spliit2goAppBuilder,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showModalBottomSheet<void>(
                context: context, builder: (_) => const SizedBox(height: 100)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final barrier = tester.getRect(find.byType(ModalBarrier).last);
    expect(barrier.bottom, 800);
  });
}
