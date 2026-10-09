import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/theme/motion_policy.dart';

/// Shows a card anchored to the widget that owns [anchorContext].
///
/// The card opens above the anchor when there is room (player controls sit at
/// the bottom of the window) and below it otherwise, always clamped inside the
/// root overlay. A small tail points at the anchor and the card grows out of
/// it. Clicking outside, including on the anchor itself, or pressing Escape
/// dismisses it; the barrier swallows that click so an anchor button behaves
/// like a toggle.
Future<T?> showDesktopAnchoredPopover<T>({
  required BuildContext anchorContext,
  required WidgetBuilder builder,
  double width = 400,
  double maxHeight = 640,
}) {
  final navigator = Navigator.of(anchorContext, rootNavigator: true);
  final overlayBox = navigator.overlay?.context.findRenderObject();
  final anchorBox = anchorContext.findRenderObject();
  var anchorRect = Rect.zero;
  var overlaySize = Size.zero;
  if (overlayBox is RenderBox &&
      anchorBox is RenderBox &&
      anchorBox.attached &&
      anchorBox.hasSize) {
    final topLeft = anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    anchorRect = topLeft & anchorBox.size;
    overlaySize = overlayBox.size;
  }
  // Player controls live at the bottom of the window, so most popovers open
  // upwards; the entrance rises towards the card from the anchor side.
  final opensUpward =
      overlaySize.height == 0 || anchorRect.center.dy > overlaySize.height / 2;
  final growFrom = overlaySize.isEmpty
      ? Alignment.center
      : Alignment(
          (anchorRect.center.dx / overlaySize.width) * 2 - 1,
          (anchorRect.center.dy / overlaySize.height) * 2 - 1,
        );
  final motion = MotionPolicy.of(anchorContext);
  // Written by the layout once it knows which side the card landed on.
  final tailPointsDown = ValueNotifier<bool>(opensUpward);
  final result = showGeneralDialog<T>(
    context: anchorContext,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(anchorContext)
        .modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: motion.reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 200),
    pageBuilder: (context, _, _) {
      final colors = Theme.of(context).colorScheme;
      final radius = NavisTokens.of(context).panelRadius;
      final border = colors.outlineVariant.withValues(alpha: 0.4);
      return CustomMultiChildLayout(
        delegate: _AnchoredPopoverLayout(
          anchor: anchorRect,
          width: width,
          maxHeight: maxHeight,
          cornerRadius: radius,
          tailPointsDown: tailPointsDown,
        ),
        children: [
          LayoutId(
            id: _PopoverSlot.card,
            child: Material(
              key: const ValueKey<String>('desktopAnchoredPopover'),
              color: colors.surfaceContainerHigh,
              elevation: 12,
              // Flat drops the hand-set black shadow.
              shadowColor: NavisColorStyleData.of(context).flat
                  ? Colors.transparent
                  : Colors.black.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius),
                side: BorderSide(color: border),
              ),
              clipBehavior: Clip.antiAlias,
              child: AnimatedSize(
                duration: motion.surface,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: builder(context),
              ),
            ),
          ),
          LayoutId(
            id: _PopoverSlot.tail,
            child: CustomPaint(
              size: _tailSize,
              painter: _TailPainter(
                fill: colors.surfaceContainerHigh,
                edge: border,
                pointsDown: tailPointsDown,
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (context, animation, _, child) {
      if (motion.reduceMotion) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, (1 - curved.value) * (opensUpward ? 6 : -6)),
            child: child,
          ),
          child: ScaleTransition(
            alignment: growFrom,
            scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
  return result.whenComplete(tailPointsDown.dispose);
}

enum _PopoverSlot { card, tail }

/// Size of the tail that points from the card edge at the anchor.
const _tailSize = Size(20, 9);

class _AnchoredPopoverLayout extends MultiChildLayoutDelegate {
  new({
    required this.anchor,
    required this.width,
    required this.maxHeight,
    required this.cornerRadius,
    required this.tailPointsDown,
  });

  static const _margin = 12.0;
  static const _gap = 10.0;
  static const _minUsefulHeight = 240.0;

  final Rect anchor;
  final double width;
  final double maxHeight;
  final double cornerRadius;
  final ValueNotifier<bool> tailPointsDown;

  @override
  void performLayout(Size size) {
    final spaceAbove = anchor.top - _margin - _gap;
    final spaceBelow = size.height - anchor.bottom - _margin - _gap;
    final resolvedWidth = math.max<double>(
      0,
      math.min(width, size.width - 2 * _margin),
    );
    final fullHeight = math.max<double>(0, size.height - 2 * _margin);
    var resolvedHeight = math.min(maxHeight, math.max(spaceAbove, spaceBelow));
    if (resolvedHeight < _minUsefulHeight) {
      resolvedHeight = math.min(maxHeight, fullHeight);
    }
    final card = layoutChild(
      _PopoverSlot.card,
      BoxConstraints(
        minWidth: resolvedWidth,
        maxWidth: resolvedWidth,
        maxHeight: math.min(resolvedHeight, fullHeight),
      ),
    );
    final maxX = math.max(_margin, size.width - card.width - _margin);
    final x = (anchor.center.dx - card.width / 2).clamp(_margin, maxX);
    final fitsAbove = card.height <= spaceAbove;
    final fitsBelow = card.height <= spaceBelow;
    final above = fitsAbove || (!fitsBelow && spaceAbove >= spaceBelow);
    final rawY = above ? anchor.top - _gap - card.height : anchor.bottom + _gap;
    final maxY = math.max(_margin, size.height - card.height - _margin);
    final y = rawY.clamp(_margin, maxY);
    positionChild(_PopoverSlot.card, Offset(x, y));

    layoutChild(_PopoverSlot.tail, BoxConstraints.tight(_tailSize));
    // Only draw the tail when the card really sits beside the anchor.
    final adjacent = above
        ? (y + card.height - (anchor.top - _gap)).abs() < 0.5
        : (y - (anchor.bottom + _gap)).abs() < 0.5;
    final minTailX = x + cornerRadius;
    final maxTailX = x + card.width - cornerRadius - _tailSize.width;
    if (anchor.isEmpty || !adjacent || maxTailX < minTailX) {
      positionChild(_PopoverSlot.tail, const Offset(-1000, -1000));
      return;
    }
    final tailX = (anchor.center.dx - _tailSize.width / 2).clamp(
      minTailX,
      maxTailX,
    );
    positionChild(
      _PopoverSlot.tail,
      above
          ? Offset(tailX, y + card.height - 1)
          : Offset(tailX, y - _tailSize.height + 1),
    );
    tailPointsDown.value = above;
  }

  @override
  bool shouldRelayout(_AnchoredPopoverLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      width != oldDelegate.width ||
      maxHeight != oldDelegate.maxHeight ||
      cornerRadius != oldDelegate.cornerRadius;
}

/// The small triangle joining the card to its anchor.
class _TailPainter extends CustomPainter {
  new({required this.fill, required this.edge, required this.pointsDown})
    : super(repaint: pointsDown);

  final Color fill;
  final Color edge;
  final ValueNotifier<bool> pointsDown;

  @override
  void paint(Canvas canvas, Size size) {
    final down = pointsDown.value;
    final baseY = down ? 0.0 : size.height;
    final tipY = down ? size.height : 0.0;
    final path = Path()
      ..moveTo(0, baseY)
      ..lineTo(size.width / 2, tipY)
      ..lineTo(size.width, baseY)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      Path()
        ..moveTo(0, baseY)
        ..lineTo(size.width / 2, tipY)
        ..lineTo(size.width, baseY),
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_TailPainter oldDelegate) =>
      fill != oldDelegate.fill ||
      edge != oldDelegate.edge ||
      pointsDown != oldDelegate.pointsDown;
}
