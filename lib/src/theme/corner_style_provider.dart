import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/theme/navis_corner_style.dart';

/// The chrome corner style. Prototype: held in memory (default `rounded`),
/// with no persistence or settings UI yet. A diagnostics or screenshot
/// harness can flip it through [CornerStyleController.set].
final cornerStyleProvider =
    NotifierProvider<CornerStyleController, NavisCornerStyle>(
      CornerStyleController.new,
    );

class CornerStyleController extends Notifier<NavisCornerStyle> {
  @override
  NavisCornerStyle build() => NavisCornerStyle.rounded;

  // A method (not a setter) so harnesses can call it through the notifier.
  // ignore: use_setters_to_change_properties
  void set(NavisCornerStyle style) => state = style;
}
