import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/utils/markdown_note.dart';
import 'package:spliit2go/widgets/notes_text.dart';

// Issue #311: links tappable in every note, markdown only when opted in.
void main() {
  Future<List<Uri>> pump(WidgetTester tester, String notes, {bool opens = true}) async {
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: NotesText(notes, openLink: (url) async {
          opened.add(url);
          return opens;
        }),
      ),
    ));
    return opened;
  }

  /// The plain note's spans that link somewhere.
  List<TextSpan> links(WidgetTester tester) {
    final root = tester.widget<SelectableText>(find.byType(SelectableText)).textSpan!;
    final found = <TextSpan>[];
    root.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) found.add(span);
      return true;
    });
    return found;
  }

  testWidgets('a plain note stays as written, its web addresses tappable', (tester) async {
    final opened = await pump(tester, '# Not a heading\nBooked at https://example.test/stay?id=1.\n*Paid* by card');

    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.textContaining('# Not a heading', findRichText: true), findsOneWidget);
    expect(find.textContaining('*Paid* by card', findRichText: true), findsOneWidget);
    final link = links(tester).single;
    // The sentence's period isn't part of the address.
    expect(link.text, 'https://example.test/stay?id=1');

    (link.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pump();
    expect(opened, [Uri.parse('https://example.test/stay?id=1')]);
  });

  testWidgets('a tap on the address opens it, inside selectable text', (tester) async {
    final opened = await pump(tester, 'Booked at https://example.test/stay ok');
    final text = tester.getRect(find.byType(EditableText));
    // 'Booked at ' is 10 of 38 characters: the address is around 45%.
    await tester.tapAt(Offset(text.left + text.width * 0.45, text.center.dy));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://example.test/stay')]);
  });

  testWidgets('a closing parenthesis stays when the address opened one (PR #312 review)', (tester) async {
    await pump(tester, 'See https://en.wikipedia.org/wiki/Paris_(mythology). Or (https://example.test/a), later');
    expect(links(tester).map((l) => l.text),
        ['https://en.wikipedia.org/wiki/Paris_(mythology)', 'https://example.test/a']);
  });

  testWidgets('a plain note without an address has no links', (tester) async {
    await pump(tester, 'Split the tip');
    expect(links(tester), isEmpty);
  });

  testWidgets('a markdown note is rendered, the marker hidden, line breaks kept', (tester) async {
    await pump(tester, '$markdownMarker\n## Hotel\n**Paid** by card\nRoom 25');

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.textContaining(markdownMarker, findRichText: true), findsNothing);
    expect(find.textContaining('##', findRichText: true), findsNothing);
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('Hotel', findRichText: true), findsOneWidget);
    // Not joined into one line with the one before.
    expect(find.textContaining('by card\nRoom 25', findRichText: true), findsOneWidget);
  });

  testWidgets('a markdown link opens; one that can\'t says so', (tester) async {
    final opened = await pump(tester, '$markdownMarker\nSee [the booking](https://example.test/b)', opens: false);

    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    body.onTapLink!('the booking', 'https://example.test/b', '');
    await tester.pump();

    expect(opened, [Uri.parse('https://example.test/b')]);
    expect(find.text("Couldn't open https://example.test/b."), findsOneWidget);
  });

  testWidgets('a markdown link to another scheme isn\'t opened', (tester) async {
    final opened = await pump(tester, '$markdownMarker\n[Call](tel:+15551234) or [file](file:///etc/hosts)');

    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    body.onTapLink!('Call', 'tel:+15551234', '');
    await tester.pump();
    expect(opened, isEmpty);
    expect(find.text("Couldn't open tel:+15551234."), findsOneWidget);
  });

  // #325: showing a note mustn't contact the host of an image in it.
  testWidgets('a markdown image shows its alt text, not the image', (tester) async {
    final opened = await pump(tester, '$markdownMarker\nReceipt: ![the receipt](https://external.test/r.png)');

    expect(find.byType(Image), findsNothing);
    expect(find.text('the receipt'), findsOneWidget);
    expect(opened, isEmpty);

    await tester.tap(find.byTooltip('Open image'));
    await tester.pump();
    expect(opened, [Uri.parse('https://external.test/r.png')]);
  });

  testWidgets('an image without alt text says Image; one that isn\'t on the web has no open button',
      (tester) async {
    await pump(tester, '$markdownMarker\n![](https://external.test/a.png)\n\n![local](file:///tmp/b.png)');

    expect(find.byType(Image), findsNothing);
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('local'), findsOneWidget);
    expect(find.byTooltip('Open image'), findsOneWidget);
  });

  testWidgets('an image inside a link: its text opens the link', (tester) async {
    final opened = await pump(tester, '$markdownMarker\n[![badge](https://external.test/b.svg)](https://example.test/ci)');

    expect(find.byType(Image), findsNothing);
    await tester.tap(find.text('badge'));
    await tester.pump();
    expect(opened, [Uri.parse('https://example.test/ci')]);
  });

  // #330: and it looks like one, unlike an image that isn't in a link.
  testWidgets('an image inside a link has its alt text styled as the link', (tester) async {
    await pump(tester,
        '$markdownMarker\n[![badge](https://external.test/b.svg#20x20)](https://example.test/ci)\n\n![plain](https://external.test/b.svg)');

    final primary = Theme.of(tester.element(find.text('badge'))).colorScheme.primary;
    final badge = tester.widget<Text>(find.text('badge')).style;
    expect(badge?.decoration, TextDecoration.underline);
    expect(badge?.color, primary);
    expect(tester.getSemantics(find.text('badge')), isSemantics(isLink: true, label: 'badge'));

    final plain = tester.widget<Text>(find.text('plain')).style;
    expect(plain?.decoration, isNot(TextDecoration.underline));
  });
}
