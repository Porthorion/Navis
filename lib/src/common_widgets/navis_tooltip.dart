import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

/// Shows the explanatory hover label without Material [Tooltip]'s
/// [OverlayPortal] semantics reparenting.
///
/// Flutter 3.47.1 can retain stale semantics children when an overlay portal is
/// repeatedly shown and hidden. The description stays on the target;
/// the overlay is deliberately visual-only, including below ExcludeSemantics.
class NavisTooltip extends StatefulWidget {
  const new({
    required this.message,
    required this.child,
    super.key,
    this.excludeFromSemantics = false,
    this.enableLongPress = true,
    this.bubbleKey,
  });

  static const defaultBubbleKey = ValueKey<String>('navis-tooltip-bubble');

  final String message;
  final Widget child;
  final bool excludeFromSemantics;
  final bool enableLongPress;
  final Key? bubbleKey;

  @override
  State<NavisTooltip> createState() => _NavisTooltipState();
}

class _NavisTooltipState extends State<NavisTooltip> {
  static const _defaultWaitDuration = Duration(milliseconds: 500);

  OverlayEntry? _entry;
  Timer? _showTimer;
  Timer? _hideTimer;

  void _handleEnter(PointerEnterEvent event) {
    _showTimer?.cancel();
    final waitDuration =
        TooltipTheme.of(context).waitDuration ?? _defaultWaitDuration;
    if (waitDuration == Duration.zero) {
      _show();
      return;
    }
    _showTimer = Timer(waitDuration, _show);
  }

  void _handleExit(PointerExitEvent event) {
    _hide();
  }

  void _show() {
    _showTimer?.cancel();
    _showTimer = null;
    if (!mounted || _entry != null) return;
    final overlay = Overlay.maybeOf(context);
    final targetBox = context.findRenderObject();
    final overlayBox = overlay?.context.findRenderObject();
    if (overlay == null ||
        targetBox is! RenderBox ||
        overlayBox is! RenderBox ||
        !targetBox.attached ||
        !overlayBox.attached ||
        !targetBox.hasSize ||
        !overlayBox.hasSize ||
        widget.message.isEmpty ||
        !TooltipVisibility.of(context) ||
        !TickerMode.valuesOf(context).enabled) {
      return;
    }
    final themes = InheritedTheme.capture(from: context, to: overlay.context);
    final target = targetBox.localToGlobal(
      targetBox.size.center(Offset.zero),
      ancestor: overlayBox,
    );
    final verticalOffset = (targetBox.size.height / 2) + 8;
    final entry = OverlayEntry(
      builder: (context) => themes.wrap(
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: CustomSingleChildLayout(
                delegate: _NavisTooltipPositionDelegate(
                  target: target,
                  verticalOffset: verticalOffset,
                ),
                child: _NavisTooltipBubble(
                  message: widget.message,
                  bubbleKey: widget.bubbleKey,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  void _hide() {
    _showTimer?.cancel();
    _showTimer = null;
    _hideTimer?.cancel();
    _hideTimer = null;
    final entry = _entry;
    _entry = null;
    entry?.remove();
    entry?.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TooltipVisibility.of(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _hide();
    }
  }

  @override
  void didUpdateWidget(NavisTooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message) _entry?.markNeedsBuild();
  }

  @override
  void deactivate() {
    _hide();
    super.deactivate();
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.enableLongPress
        ? GestureDetector(
            onLongPress: _show,
            onLongPressEnd: (_) {
              _hideTimer?.cancel();
              _hideTimer = Timer(
                TooltipTheme.of(context).showDuration ??
                    const Duration(milliseconds: 1500),
                _hide,
              );
            },
            child: widget.child,
          )
        : widget.child;
    return Semantics(
      tooltip: widget.excludeFromSemantics ? null : widget.message,
      child: MouseRegion(
        onEnter: _handleEnter,
        onExit: _handleExit,
        child: Listener(onPointerDown: (_) => _hide(), child: child),
      ),
    );
  }
}

class _NavisTooltipPositionDelegate extends SingleChildLayoutDelegate {
  const new({required this.target, required this.verticalOffset});

  final Offset target;
  final double verticalOffset;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return positionDependentBox(
      size: size,
      childSize: childSize,
      target: target,
      verticalOffset: verticalOffset,
      preferBelow: false,
    );
  }

  @override
  bool shouldRelayout(_NavisTooltipPositionDelegate oldDelegate) {
    return target != oldDelegate.target ||
        verticalOffset != oldDelegate.verticalOffset;
  }
}

class _NavisTooltipBubble extends StatelessWidget {
  const new({required this.message, this.bubbleKey});

  final String message;
  final Key? bubbleKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24, maxWidth: 280),
      child: Align(
        widthFactor: 1,
        heightFactor: 1,
        child: DecoratedBox(
          key: bubbleKey ?? NavisTooltip.defaultBubbleKey,
          decoration: BoxDecoration(
            color: colors.inverseSurface,
            borderRadius: NavisShapeData.of(context).xsAll,
            boxShadow: NavisColorStyleData.of(context).flatSurfaces
                ? null
                : const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onInverseSurface),
            ),
          ),
        ),
      ),
    );
  }
}
