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

/// A mark is crossed back only once the pull is this much of the trigger
/// distance behind it, so a finger resting on a mark does not flutter.
const double _hysteresis = 0.06;

const List<double> _tickMarks = <double>[0.25, 0.5, 0.75];

class _NavisRefreshIndicatorState extends State<NavisRefreshIndicator> {
  bool _tracking = false;
  bool _refreshing = false;
  double _offset = 0;
  int _stage = 0;
  bool _armed = false;

  Future<void> _refresh() async {
    _refreshing = true;
    try {
      await widget.onRefresh();
      NavisHaptics.confirm();
    } finally {
      _refreshing = false;
    }
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
    } else if (!_tracking) {
      return false;
    } else if (notification is ScrollUpdateNotification) {
      _offset -= notification.scrollDelta ?? 0;
      _update(metrics.viewportDimension);
    } else if (notification is OverscrollNotification) {
      _offset -= notification.overscroll;
      _update(metrics.viewportDimension);
    } else if (notification is ScrollEndNotification) {
      _tracking = false;
    }
    return false;
  }

  void _update(double viewport) {
    final fraction = math.max(0, _offset) / (viewport * _triggerShare);
    if (!_armed && fraction >= 1) {
      _armed = true;
      _stage = _tickMarks.length;
      NavisHaptics.thresholdOn();
      return;
    }
    if (_armed) {
      if (fraction >= 1 - _hysteresis) return;
      _armed = false;
      NavisHaptics.thresholdOff();
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
