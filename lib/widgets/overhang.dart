import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// [child] taking [reach] less room than its height above and below,
/// which it draws and takes taps over (#263): a tap target taller than
/// its line, over what's around it, without moving it. Its parent must
/// cover the reach: Flutter only hit-tests inside a box.
class Overhang extends SingleChildRenderObjectWidget {
  const Overhang({super.key, required this.reach, required super.child});

  final double reach;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderOverhang(reach);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) => (renderObject as _RenderOverhang).reach = reach;
}

class _RenderOverhang extends RenderShiftedBox {
  _RenderOverhang(this._reach) : super(null);

  double _reach;
  set reach(double value) {
    if (value == _reach) return;
    _reach = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints.loosen().copyWith(maxHeight: double.infinity), parentUsesSize: true);
    (child.parentData! as BoxParentData).offset = Offset(0, -_reach);
    size = constraints.constrain(Size(child.size.width, child.size.height - 2 * _reach));
  }

  // Into the reach too, which is outside this box.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!hitTestChildren(result, position: position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}
