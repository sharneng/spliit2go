import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/widgets/bottom_inset.dart';

void main() {
  testWidgets('adds the bottom safe-area inset to the padding (#197)', (tester) async {
    late EdgeInsets padding;
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(padding: EdgeInsets.only(top: 50, bottom: 34)),
      child: Builder(builder: (context) {
        padding = withBottomInset(context, const EdgeInsets.only(top: 16, bottom: 88));
        return const SizedBox();
      }),
    ));
    expect(padding, const EdgeInsets.only(top: 16, bottom: 88 + 34));
  });
}
