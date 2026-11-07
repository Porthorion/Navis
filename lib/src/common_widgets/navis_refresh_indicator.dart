import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';

/// A pull-to-refresh that feels like a pull: a fine tick at each quarter of the
/// way to the trigger, a firm click at the trigger point (and a softer one if
/// the pull goes back before it), and a soft confirm when the refresh finishes.
///
/// It wraps [RefreshIndicator] (or [RefreshIndicator.noSpinner]) and measures
/// the pull the way that widget does, so the firm click lands exactly where
/// letting go would refresh.
class NavisRefreshIndicator extends StatefulWidget {
  const new({
    required this.onRefresh,
    required this.child,
    this.noSpinner = false,
    this.onStatusChange,
    super.key,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  /// Draws no built-in spinner, for a screen that paints its own.
  final bool noSpinner;

  /// Pull status, which [RefreshIndicator] reports only without its spinner.
  final ValueChanged<RefreshIndicatorStatus?>? onStatusChange;

  @override
  State<NavisRefreshIndicator> createState() => _NavisRefreshIndicatorState();
}

/// [RefreshIndicator] arms after dragging this share of the viewport height.
const double _triggerShare = 0.25;

/// A mark, or the trigger, clicks again only once the pull has backed off this
/// much of the trigger distance, so a finger resting on it does not flutter.
const double _hysteresis = 0.06;

const List<double> _tickMarks = <double>[0.25, 0.5, 0.75];

class _NavisRefreshIndicatorState extends State<NavisRefreshIndicator> {
  bool _tracking = false;
  bool _refreshing = false;
  double _offset = 0;
  int _stage = 0;
  bool _armed = false;

  /// False after the trigger click turned off, until the pull has backed off
  /// [_hysteresis] below it, so a finger resting on the line does not re-click.
  bool _canArm = true;
  Timer? _settling;

  /// [RefreshIndicator] ignores new pulls while its spinner finishes (its scale
  /// animation is 200 ms), so pulls stay silent a little longer than the
  /// refresh itself.
  static const _doneAnimation = Duration(milliseconds: 300);

  Future<void> _refresh() async {
    _settling?.cancel();
    _refreshing = true;
    try {
      await widget.onRefresh();
      NavisHaptics.confirm();
    } finally {
      _settling = Timer(_doneAnimation, () => _refreshing = false);
    }
  }

  @override
  void dispose() {
    _settling?.cancel();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (notification.depth != 0 ||
        metrics.axisDirection != AxisDirection.down) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _tracking =
          !_refreshing &&
          notification.dragDetails != null &&
          metrics.extentBefore == 0;
      _offset = 0;
      _stage = 0;
      _armed = false;
      _canArm = true;
    } else if (!_tracking) {
      return false;
    } else if (notification is ScrollEndNotification) {
      _tracking = false;
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      // Only a finger pulls: the spring-back after letting go has no drag.
      _offset -= notification.scrollDelta ?? 0;
      _update(metrics.viewportDimension);
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      _offset -= notification.overscroll;
      _update(metrics.viewportDimension);
    }
    return false;
  }

  void _update(double viewport) {
    final fraction = math.max(0, _offset) / (viewport * _triggerShare);
    // Armed means exactly "letting go now refreshes", as RefreshIndicator
    // decides: so it turns off the moment the pull drops below the trigger.
    if (_armed) {
      if (fraction >= 1) return;
      _armed = false;
      _canArm = fraction < 1 - _hysteresis;
      NavisHaptics.thresholdOff();
      return;
    }
    if (fraction < 1 - _hysteresis) _canArm = true;
    if (_canArm && fraction >= 1) {
      _armed = true;
      _stage = _tickMarks.length;
      NavisHaptics.thresholdOn();
      return;
    }
    final stage = _tickMarks.where((mark) => fraction >= mark).length;
    final rising = stage > _stage;
    final falling =
        _stage > 0 && fraction < _tickMarks[_stage - 1] - _hysteresis;
    if (rising) {
      _stage = stage;
      NavisHaptics.frequentTick();
    } else if (falling) {
      _stage = _tickMarks
          .where((mark) => fraction >= mark - _hysteresis)
          .length;
      NavisHaptics.frequentTick();
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: widget.noSpinner
          ? RefreshIndicator.noSpinner(
              onRefresh: _refresh,
              onStatusChange: widget.onStatusChange,
              child: widget.child,
            )
          : RefreshIndicator(onRefresh: _refresh, child: widget.child),
    );
  }
}
