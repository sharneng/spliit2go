import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/main.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/category_icon.dart';
import 'package:spliit2go/widgets/group_monogram.dart';
import 'package:spliit2go/widgets/grouped_section.dart';
import 'package:spliit2go/widgets/top_bar_buttons.dart';

// #294: glyphs grow with the text size, by where they sit.
void main() {
  Future<void> pumpAt(WidgetTester tester, double scale, Widget child) async {
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MaterialApp(
      theme: spliit2goLightTheme,
      builder: spliit2goAppBuilder,
      home: Scaffold(body: ListView(children: [child])),
    ));
  }

  Widget glyphs() => const Column(children: [
        Icon(Icons.translate, key: Key('inline')),
        GroupedRow(leading: Icon(Icons.settings, key: Key('leading')), title: Text('Settings')),
        Monogram(key: Key('monogram'), name: 'Ana', color: Colors.teal, radius: 12),
        CategoryIconGlyph(key: Key('header'), category: null, size: 44, scales: false),
      ]);

  double width(WidgetTester tester, String key) => tester.getSize(find.byKey(Key(key))).width;

  testWidgets('at the usual text size, nothing changes', (tester) async {
    await pumpAt(tester, 1, glyphs());
    expect(width(tester, 'inline'), 24);
    expect(width(tester, 'leading'), 24);
    expect(width(tester, 'monogram'), 24);
    expect(width(tester, 'header'), 44);
  });

  testWidgets('at twice the size, by its square root; the header as it is', (tester) async {
    await pumpAt(tester, 2, glyphs());
    final root2 = math.sqrt(2);
    expect(width(tester, 'inline'), moreOrLessEquals(24 * root2));
    expect(width(tester, 'leading'), moreOrLessEquals(24 * root2));
    expect(width(tester, 'monogram'), moreOrLessEquals(24 * root2));
    expect(width(tester, 'header'), 44);
  });

  testWidgets('the top bar\'s buttons, and icon buttons, stay as they are', (tester) async {
    await pumpAt(
        tester,
        2,
        Row(children: [
          TopBarButtons(children: [
            IconButton(onPressed: () {}, icon: const Icon(Icons.edit, key: Key('edit'))),
            IconButton(onPressed: () {}, icon: const Icon(Icons.delete, key: Key('delete'))),
          ]),
        ]));
    expect(width(tester, 'edit'), 24);
    expect(width(tester, 'delete'), 24);
  });

  testWidgets('a text button\'s icon grows with its label', (tester) async {
    await pumpAt(tester, 2,
        TextButton.icon(onPressed: () {}, icon: const Icon(Icons.copy, key: Key('icon')), label: const Text('Copy')));
    expect(width(tester, 'icon'), moreOrLessEquals(18 * math.sqrt(2)));
  });

  testWidgets('at four times, twice', (tester) async {
    await pumpAt(tester, 4, glyphs());
    expect(width(tester, 'inline'), 48);
    expect(width(tester, 'leading'), 48);
    expect(width(tester, 'monogram'), 48);
  });
}
