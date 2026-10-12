import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Whether a list's values all go under their labels (Kenneth, #294): when
/// the widest would leave the labels less than half of [row], what's left
/// after [label]'s fixed part (a monogram and its gap) and [widest] (the
/// widest value with its gap). One answer for every row, so they don't go
/// under one by one as names grow: Paid for, in the form and the details.
bool valuesGoUnder({required double row, required double label, required double widest}) =>
    row - label - widest < row / 2;

/// [text]'s width in [style] at the screen's text size, for measuring a
/// value before it's laid out.
double measuredTextWidth(BuildContext context, String text, TextStyle? style) {
  final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context))
    ..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// A label and its value on one line when both fit at their full width,
/// the value at the line's end; the value under the label when they don't
/// (#263). Measured, as the Stats rows' (#103), rather than switched at a
/// text size: a short label stays beside its value at any size, a long
/// one in French goes under sooner.
///
/// Beside, the value gets the rest of the line, so a text field fills it.
/// Under, it's [runGap] below the label, as wide as it needs, and at the
/// line's end as it is beside: values line up on one edge (Kenneth, #294).
///
/// [under] decides instead of measuring, for rows that decide together,
/// as the split's (#294). Beside, a label that doesn't fit then wraps.
class LabelAndValue extends MultiChildRenderObjectWidget {
  LabelAndValue(
      {super.key,
      required Widget label,
      required Widget value,
      this.gap = 16,
      this.runGap = 2,
      this.under})
      : super(children: [label, value]);

  final double gap;
  final double runGap;
  final bool? under;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLabelAndValue(
      gap: gap,
      runGap: runGap,
      under: under,
      textDirection: Directionality.of(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) => (renderObject as _RenderLabelAndValue)
    ..gap = gap
    ..runGap = runGap
    ..under = under
    ..textDirection = Directionality.of(context);
}

class _ParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderLabelAndValue extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _ParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _ParentData> {
  _RenderLabelAndValue(
      {required double gap,
      required double runGap,
      required bool? under,
      required TextDirection textDirection})
      : _gap = gap,
        _runGap = runGap,
        _under = under,
        _textDirection = textDirection;

  bool? _under;
  set under(bool? value) {
    if (value == _under) return;
    _under = value;
    markNeedsLayout();
  }

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

  RenderBox get _label => firstChild!;
  RenderBox get _value => childAfter(firstChild!)!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ParentData) child.parentData = _ParentData();
  }

  bool _fits(double width) =>
      _label.getMaxIntrinsicWidth(double.infinity) + _gap + _value.getMaxIntrinsicWidth(double.infinity) <= width;

  bool _beside(double width) => switch (_under) { true => false, false => true, null => _fits(width) };

  /// Beside, the label's width: all it asks for, or what the value leaves.
  double _labelWidth(double width) => math.min(_label.getMaxIntrinsicWidth(double.infinity),
      math.max(0, width - _gap - _value.getMaxIntrinsicWidth(double.infinity)));

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(_label.getMinIntrinsicWidth(double.infinity), _value.getMinIntrinsicWidth(double.infinity));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _label.getMaxIntrinsicWidth(double.infinity) + _gap + _value.getMaxIntrinsicWidth(double.infinity);

  @override
  double computeMinIntrinsicHeight(double width) => computeMaxIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _beside(width)
      ? math.max(_label.getMaxIntrinsicHeight(_labelWidth(width)), _value.getMaxIntrinsicHeight(double.infinity))
      : _label.getMaxIntrinsicHeight(width) + _runGap + _value.getMaxIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.maxWidth;
    Size lay(RenderBox child, BoxConstraints c) => dry ? child.getDryLayout(c) : (child..layout(c, parentUsesSize: true)).size;
    void place(RenderBox child, double start, double top, Size childSize) {
      if (dry) return;
      final x = _textDirection == TextDirection.ltr ? start : width - start - childSize.width;
      (child.parentData! as _ParentData).offset = Offset(x, top);
    }

    if (_beside(width)) {
      final labelWidth = _labelWidth(width);
      final label = lay(_label, BoxConstraints(maxWidth: labelWidth));
      final value = lay(_value, BoxConstraints(maxWidth: math.max(0, width - labelWidth - _gap)));
      final height = math.max(label.height, value.height);
      place(_label, 0, (height - label.height) / 2, label);
      place(_value, width - value.width, (height - value.height) / 2, value);
      return constraints.constrain(Size(width, height));
    }
    final label = lay(_label, BoxConstraints(maxWidth: width));
    final value = lay(_value, BoxConstraints(maxWidth: width));
    place(_label, 0, 0, label);
    place(_value, width - value.width, label.height + _runGap, value);
    return constraints.constrain(Size(width, label.height + _runGap + value.height));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);
}
