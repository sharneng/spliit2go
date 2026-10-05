import 'package:flutter/material.dart';

/// The height of the system's bottom inset (the home indicator, Android's
/// gesture or button bar), which `spliit2goAppBuilder` keeps every screen
/// out of. Provided there, above its SafeArea, since below it the
/// MediaQuery no longer has it.
class AppBottomInset extends InheritedWidget {
  const AppBottomInset({super.key, required this.height, required super.child});

  final double height;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppBottomInset>()?.height ?? 0;

  @override
  bool updateShouldNotify(AppBottomInset oldWidget) => height != oldWidget.height;
}

/// Paints [color] into the strip under the screen, behind the system's
/// bottom inset, so that strip continues whatever the screen ends with
/// rather than showing the app's plain backdrop (#186 review). Takes no
/// space itself: the strip is below its bottom edge.
///
/// A screen whose bottom isn't the theme's plain background puts one at
/// its very bottom: as a [Scaffold.bottomNavigationBar] when it has none
/// ([BottomInsetFill.bar]), or around the one it has.
class BottomInsetFill extends StatelessWidget {
  const BottomInsetFill({super.key, required this.color, required this.child});

  /// Nothing but the fill, for a [Scaffold.bottomNavigationBar] slot.
  const BottomInsetFill.bar({super.key, required this.color})
      : child = const SizedBox(width: double.infinity);

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _FillBelow(color, AppBottomInset.of(context)), child: child);
}

class _FillBelow extends CustomPainter {
  _FillBelow(this.color, this.height);

  final Color color;
  final double height;

  @override
  void paint(Canvas canvas, Size size) {
    if (height <= 0) return;
    canvas.drawRect(
        Rect.fromLTWH(0, size.height, size.width, height), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_FillBelow old) => old.color != color || old.height != height;
}
