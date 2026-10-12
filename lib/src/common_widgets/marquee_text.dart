import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Calm travel speed of a scrolling title, in logical pixels per second.
const double kMarqueeSpeed = 35;

/// How long a scrolling title rests at its start before moving.
const Duration kMarqueeStartPause = Duration(milliseconds: 1750);

/// How long a scrolling title rests at its end before jumping back.
const Duration kMarqueeEndPause = Duration(milliseconds: 800);

/// A single-line [Text] that scrolls sideways when it is wider than the space
/// it gets.
///
/// A title that fits is a plain [Text]. A longer one rests at its start,
/// scrolls to its end at [kMarqueeSpeed], rests again, snaps back and repeats.
/// Reduced motion keeps the title still, truncated with an ellipsis. The
/// ticker runs only while the title is on screen (a covered route or tab mutes
/// it through [TickerMode]; [VisibilityDetector] stops it when scrolled away),
/// and the full title is always the semantics label.
///
/// [passes] limits how many times it scrolls before resting at its start
/// (null repeats for as long as it is shown), for text that stays on screen
/// for long stretches, such as a status banner.
class MarqueeText extends StatelessWidget {
  const new(this.text, {required this.style, this.passes, super.key});

  final String text;
  final TextStyle style;
  final int? passes;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final merged = DefaultTextStyle.of(context).style.merge(style);
    final painter = TextPainter(
      text: TextSpan(text: text, style: merged),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final textWidth = painter.width.ceilToDouble();
    final lineHeight = painter.height;
    painter.dispose();
    final plain = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (MotionPolicy.of(context).reduceMotion) return plain;
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflow = textWidth - constraints.maxWidth;
        if (!constraints.hasBoundedWidth || overflow <= 0) return plain;
        return Semantics(
          label: text,
          excludeSemantics: true,
          child: SizedBox(
            height: lineHeight,
            child: _MarqueeScroller(
              text: text,
              style: style,
              textWidth: textWidth,
              overflow: overflow,
              passes: passes,
            ),
          ),
        );
      },
    );
  }
}

class _MarqueeScroller extends StatefulWidget {
  const new({
    required this.text,
    required this.style,
    required this.textWidth,
    required this.overflow,
    required this.passes,
  });

  final String text;
  final TextStyle style;
  final double textWidth;

  /// How far the text must travel to show its end.
  final double overflow;

  final int? passes;

  @override
  State<_MarqueeScroller> createState() => _MarqueeScrollerState();
}

class _MarqueeScrollerState extends State<_MarqueeScroller>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  final Key _visibilityKey = UniqueKey();
  bool _visible = true;
  bool _done = false;
  Duration _travel = Duration.zero;

  @override
  void initState() {
    super.initState();
    _configure();
  }

  @override
  void didUpdateWidget(_MarqueeScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.overflow != widget.overflow ||
        oldWidget.text != widget.text) {
      _configure();
    }
  }

  void _configure() {
    _travel = Duration(
      microseconds: (widget.overflow / kMarqueeSpeed * 1e6).round(),
    );
    _controller.duration = kMarqueeStartPause + _travel + kMarqueeEndPause;
    _controller.value = 0;
    _done = false;
    _sync();
  }

  void _sync() {
    if (_visible) {
      if (_done || _controller.isAnimating) return;
      final passes = widget.passes;
      if (passes == null) {
        _controller.repeat();
      } else {
        unawaited(
          _controller.repeat(count: passes).orCancel.then((_) {
            if (!mounted) return;
            // Rest at the start, where the text begins.
            _done = true;
            _controller.value = 0;
          }, onError: (Object _) {}),
        );
      }
    } else {
      _controller.stop();
    }
  }

  void _visibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    _visible = info.visibleFraction > 0;
    _sync();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Distance scrolled at [t] in 0..1 of the cycle: rest, travel, rest.
  double _offsetAt(double t) {
    final total = _controller.duration!.inMicroseconds;
    final elapsed = t * total;
    final start = kMarqueeStartPause.inMicroseconds;
    final travel = _travel.inMicroseconds;
    if (elapsed <= start) return 0;
    if (elapsed >= start + travel) return widget.overflow;
    return (elapsed - start) / travel * widget.overflow;
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return VisibilityDetector(
      key: _visibilityKey,
      onVisibilityChanged: _visibilityChanged,
      child: RepaintBoundary(
        child: ClipRect(
          child: OverflowBox(
            alignment: AlignmentDirectional.centerStart,
            minWidth: 0,
            maxWidth: widget.textWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(
                  (rtl ? 1 : -1) * _offsetAt(_controller.value),
                  0,
                ),
                child: child,
              ),
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: widget.style,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
