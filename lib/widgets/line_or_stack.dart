import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// [leading], [title] and [trailing] on one line when all three fit at
/// their full width, [trailing] at the line's end; otherwise on two lines,
/// each centered: [leading] and [title], then [trailing] (Kenneth, #294).
/// Never three: "Scan receipt" at the largest text sizes, rather than its
/// words wrapping beside its icon. A [title] that doesn't fit beside
/// [leading] even so is scaled down to fit, so it stays one line.
class LineOrStack extends MultiChildRenderObjectWidget {
  LineOrStack(
      {super.key,
      required Widget leading,
      required Widget title,
      required Widget trailing,
      this.gap = 16,
      this.runGap = 4})
      : super(children: [leading, title, trailing]);

  /// Between the three on a line.
  final double gap;

  /// Between the two lines.
  final double runGap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLineOrStack(gap: gap, runGap: runGap, textDirection: Directionality.of(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) => (renderObject as _RenderLineOrStack)
    ..gap = gap
    ..runGap = runGap
    ..textDirection = Directionality.of(context);
}

class _ParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderLineOrStack extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _ParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _ParentData> {
  _RenderLineOrStack({required double gap, required double runGap, required TextDirection textDirection})
      : _gap = gap,
        _runGap = runGap,
        _textDirection = textDirection;

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  double _runGap;
  set runGap(double value) {
    if (value == _runGap) return;
    _runGap = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  List<RenderBox> get _children => getChildrenAsList();

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ParentData) child.parentData = _ParentData();
  }

  double get _lineWidth =>
      _children.fold<double>(0, (sum, child) => sum + child.getMaxIntrinsicWidth(double.infinity)) + 2 * _gap;

  bool _fits(double width) => _lineWidth <= width;

  @override
  double computeMinIntrinsicWidth(double height) {
    final [leading, _, trailing] = _children;
    return math.max(leading.getMinIntrinsicWidth(double.infinity), trailing.getMinIntrinsicWidth(double.infinity));
  }

  @override
  double computeMaxIntrinsicWidth(double height) => _lineWidth;

  @override
  double computeMinIntrinsicHeight(double width) => computeMaxIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _layout(BoxConstraints(maxWidth: width), dry: true).height;

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.maxWidth;
    final children = _children;
    Size lay(RenderBox child, BoxConstraints c) => dry ? child.getDryLayout(c) : (child..layout(c, parentUsesSize: true)).size;
    void place(RenderBox child, double start, double top, Size childSize) {
      if (dry) return;
      final x = _textDirection == TextDirection.ltr ? start : width - start - childSize.width;
      (child.parentData! as _ParentData).offset = Offset(x, top);
    }

    if (_fits(width)) {
      final [leading, title, trailing] = children;
      final leadingSize = lay(leading, BoxConstraints(maxWidth: width));
      final trailingSize = lay(trailing, BoxConstraints(maxWidth: width));
      final titleSize = lay(
          title, BoxConstraints(maxWidth: math.max(0, width - leadingSize.width - trailingSize.width - 2 * _gap)));
      final height = [leadingSize, titleSize, trailingSize].map((s) => s.height).reduce(math.max);
      place(leading, 0, (height - leadingSize.height) / 2, leadingSize);
      place(title, leadingSize.width + _gap, (height - titleSize.height) / 2, titleSize);
      place(trailing, width - trailingSize.width, (height - trailingSize.height) / 2, trailingSize);
      return constraints.constrain(Size(width, height));
    }
    final [leading, title, trailing] = children;
    final leadingSize = lay(leading, BoxConstraints(maxWidth: width));
    final titleSize = lay(title, BoxConstraints(maxWidth: math.max(0, width - leadingSize.width - _gap)));
    final firstHeight = math.max(leadingSize.height, titleSize.height);
    final start = (width - leadingSize.width - _gap - titleSize.width) / 2;
    place(leading, start, (firstHeight - leadingSize.height) / 2, leadingSize);
    place(title, start + leadingSize.width + _gap, (firstHeight - titleSize.height) / 2, titleSize);
    final trailingSize = lay(trailing, BoxConstraints(maxWidth: width));
    place(trailing, (width - trailingSize.width) / 2, firstHeight + _runGap, trailingSize);
    return constraints.constrain(Size(width, firstHeight + _runGap + trailingSize.height));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);
}
