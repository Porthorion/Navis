import 'package:flutter/widgets.dart';

/// Semantic motion timings derived from the platform accessibility setting.
///
/// Reduced motion preserves navigation and state changes while removing
/// nonessential travel and fades. Callers should use these semantic values
/// rather than introduce new hard-coded animation durations.
@immutable
class MotionPolicy {
  const new _({required this.reduceMotion});

  factory of(BuildContext context) {
    return MotionPolicy._(
      reduceMotion: MediaQuery.maybeOf(context)?.disableAnimations ?? false,
    );
  }

  final bool reduceMotion;

  Duration get navigationForward =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 280);

  Duration get navigationReverse =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 220);

  Duration get feedback =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 120);

  Duration get surface =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 180);
}
