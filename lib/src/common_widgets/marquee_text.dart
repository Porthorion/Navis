import 'dart:async';

import 'package:intl/intl.dart' show Bidi;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/utils/metadata_normalization.dart';
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
/// The ticker runs only while the title is on screen (a covered route or tab
/// mutes it through [TickerMode]; [VisibilityDetector] stops it when scrolled
/// away), and the full title is always the semantics label.
///
/// Whenever it is not moving (inactive, reduced motion, the pause before each
/// pass and after the last one) a truncated title shows its *still form*: the
/// base ellipsized and the trailing version kept whole, such as
/// "Song Name That Is L… (Radio Edit)", split by [splitTitleVersion] on the
/// same line.
///
/// [passes] limits how many times it scrolls before resting (null repeats for
/// as long as it is shown), for text that stays on screen for long stretches.
/// An inactive title ([active] false) never scrolls and creates no ticker, so
/// long lists only move the rows that are hovered or playing.
class MarqueeText extends StatelessWidget {
  const new(
    this.text, {
    required this.style,
    this.passes,
    this.active = true,
    this.textAlign = TextAlign.start,
    this.strutStyle,
    super.key,
  });

  final String text;
  final TextStyle style;
  final int? passes;
  final bool active;

  /// Alignment of a title that fits; a truncated one fills its width.
  final TextAlign textAlign;
  final StrutStyle? strutStyle;

  @override
  Widget build(BuildContext context) {
    final still = _VersionKeepingLine(
      text: text,
      style: style,
      textAlign: textAlign,
      strutStyle: strutStyle,
    );
    if (!active || MotionPolicy.of(context).reduceMotion) return still;
    final painter = _painter(context, text, style, strutStyle)..layout();
    final textWidth = painter.width.ceilToDouble();
    final lineHeight = painter.height;
    painter.dispose();
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflow = textWidth - constraints.maxWidth;
        if (!constraints.hasBoundedWidth || overflow <= 0) {
          return _oneLine(text, style, textAlign, strutStyle);
        }
        return Semantics(
          label: text,
          excludeSemantics: true,
          child: SizedBox(
            height: lineHeight,
            child: _MarqueeScroller(
              text: text,
              style: style,
              strutStyle: strutStyle,
              textWidth: textWidth,
              overflow: overflow,
              passes: passes,
              still: still,
            ),
          ),
        );
      },
    );
  }
}

TextPainter _painter(
  BuildContext context,
  String text,
  TextStyle style,
  StrutStyle? strutStyle,
) => TextPainter(
  text: TextSpan(
    text: text,
    style: DefaultTextStyle.of(context).style.merge(style),
  ),
  textDirection: Directionality.of(context),
  textScaler: MediaQuery.textScalerOf(context),
  strutStyle: strutStyle,
  maxLines: 1,
);

Text _oneLine(
  String text,
  TextStyle style,
  TextAlign textAlign,
  StrutStyle? strutStyle, [
  TextDirection? textDirection,
]) => Text(
  text,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: style,
  textAlign: textAlign,
  strutStyle: strutStyle,
  textDirection: textDirection,
);

/// The title at rest. Without a version, or when it fits, a plain [Text];
/// a truncated title with a version ellipsizes only its base.
class _VersionKeepingLine extends StatelessWidget {
  const new({
    required this.text,
    required this.style,
    required this.textAlign,
    required this.strutStyle,
  });

  final String text;
  final TextStyle style;
  final TextAlign textAlign;
  final StrutStyle? strutStyle;

  /// Share of the width a version may take before it is ellipsized too.
  static const double _maxSuffixShare = 0.6;

  @override
  Widget build(BuildContext context) {
    final plain = _oneLine(text, style, textAlign, strutStyle);
    final (:base, :suffix) = splitTitleVersion(text);
    if (suffix.isEmpty) return plain;
    final painter = _painter(context, text, style, strutStyle)..layout();
    final textWidth = painter.width.ceilToDouble();
    painter.dispose();
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || textWidth <= constraints.maxWidth) {
          return plain;
        }
        // Follow the title's own direction, not the surrounding layout's.
        final direction = Bidi.detectRtlDirectionality(text)
            ? TextDirection.rtl
            : TextDirection.ltr;
        return Semantics(
          label: text,
          excludeSemantics: true,
          child: Row(
            textDirection: direction,
            children: [
              Flexible(
                child: _oneLine(
                  base,
                  style,
                  TextAlign.start,
                  strutStyle,
                  direction,
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * _maxSuffixShare,
                ),
                child: _oneLine(
                  suffix,
                  style,
                  TextAlign.start,
                  strutStyle,
                  direction,
                ),
              ),
            ],
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
    required this.strutStyle,
    required this.textWidth,
    required this.overflow,
    required this.passes,
    required this.still,
  });

  final String text;
  final TextStyle style;
  final StrutStyle? strutStyle;
  final double textWidth;

  /// Shown at rest: the start pause and after the last pass.
  final Widget still;

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
        oldWidget.text != widget.text ||
        oldWidget.passes != widget.passes) {
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
        child: AnimatedBuilder(
          animation: _controller,
          // The full text is built once; only the offset changes per frame.
          child: Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: widget.style,
            strutStyle: widget.strutStyle,
          ),
          builder: (context, full) {
            final offset = _offsetAt(_controller.value);
            // At rest the version-keeping line; the end of the full text, and
            // so the version, is in view whenever it moves or pauses at its end.
            if (offset == 0) return widget.still;
            return ClipRect(
              child: OverflowBox(
                alignment: AlignmentDirectional.centerStart,
                minWidth: 0,
                maxWidth: widget.textWidth,
                child: Transform.translate(
                  offset: Offset((rtl ? 1 : -1) * offset, 0),
                  child: full,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
