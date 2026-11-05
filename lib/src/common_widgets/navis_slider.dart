import 'package:material_ui/material_ui.dart';

/// A material [Slider] that keeps the desktop accessibility tree intact.
///
/// `Slider` always wraps its value indicator in an `OverlayPortal`. In a
/// pushed route, Flutter 3.47 then sends the engine a semantics node that no
/// parent lists as a child (flutter/flutter#190357). The macOS and Windows
/// accessibility bridges reject it, stay failed, and freeze their native tree
/// on stale nodes, which can later crash on a pointer move
/// (flutter/flutter#193588). Giving the slider its own [Overlay] keeps the
/// portal's semantics inside the slider, so use this instead of a bare
/// `Slider` (an architecture test enforces it).
///
/// ponytail: workaround for flutter/flutter#193372 (fixed on master
/// 2026-10-19, not in 3.47.9). Replace the `Overlay.wrap` with the bare
/// `Slider` once a stable Flutter release ships that fix.
///
/// Takes the `Slider` parameters Navis uses. [sliderKey] is the inner
/// `Slider`'s key, so `find.byKey` still resolves to a `Slider`.
class NavisSlider extends StatelessWidget {
  const new({
    required this.value,
    required this.onChanged,
    super.key,
    this.sliderKey,
    this.secondaryTrackValue,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.label,
    this.activeColor,
    this.inactiveColor,
    this.secondaryActiveColor,
    this.thumbColor,
    this.overlayColor,
    this.mouseCursor,
    this.semanticFormatterCallback,
    this.focusNode,
    this.autofocus = false,
    this.allowedInteraction,
    this.padding,
    this.showValueIndicator,
  });

  final Key? sliderKey;
  final double value;
  final double? secondaryTrackValue;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final Color? activeColor;
  final Color? inactiveColor;
  final Color? secondaryActiveColor;
  final Color? thumbColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final MouseCursor? mouseCursor;
  final SemanticFormatterCallback? semanticFormatterCallback;
  final FocusNode? focusNode;
  final bool autofocus;
  final SliderInteraction? allowedInteraction;
  final EdgeInsetsGeometry? padding;
  final ShowValueIndicator? showValueIndicator;

  @override
  Widget build(BuildContext context) {
    return Overlay.wrap(
      // The overlay takes the slider's size, and the value indicator may
      // paint outside it.
      alwaysSizeToContent: true,
      clipBehavior: Clip.none,
      child: Slider(
        key: sliderKey,
        value: value,
        secondaryTrackValue: secondaryTrackValue,
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        secondaryActiveColor: secondaryActiveColor,
        thumbColor: thumbColor,
        overlayColor: overlayColor,
        mouseCursor: mouseCursor,
        semanticFormatterCallback: semanticFormatterCallback,
        focusNode: focusNode,
        autofocus: autofocus,
        allowedInteraction: allowedInteraction,
        padding: padding,
        showValueIndicator: showValueIndicator,
      ),
    );
  }
}
