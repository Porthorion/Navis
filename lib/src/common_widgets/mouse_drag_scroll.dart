import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Lets a mouse drag scroll the scrollables below it, as touch and trackpads
/// already do.
///
/// Applied per horizontal shelf rather than app-wide: a global setting would
/// also turn mouse drags into scrolls over sliders, selectable text,
/// reorderable lists and the equalizer graph.
class MouseDragScroll extends StatelessWidget {
  const MouseDragScroll({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: behavior.copyWith(
        dragDevices: <PointerDeviceKind>{
          ...behavior.dragDevices,
          PointerDeviceKind.mouse,
        },
      ),
      child: child,
    );
  }
}
