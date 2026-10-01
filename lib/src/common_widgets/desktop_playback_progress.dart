import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Keeps playback times visible beside or below the available seek space.
class DesktopPlaybackProgress extends StatelessWidget {
  const new({
    required this.elapsed,
    required this.total,
    required this.seekBar,
    required this.liveLabel,
    this.isLive = false,
    super.key,
  });
  final String elapsed;
  final String total;
  final Widget seekBar;
  final String liveLabel;
  final bool isLive;

  static TextStyle? _style(BuildContext context) =>
      Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static Size _measure(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: _style(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }

  /// Normal bars stay 116px high; scaled labels can increase their height.
  static double playerHeight(BuildContext context) =>
      math.max(116, _measure(context, '00:00:00').height * 2 + 28 + 44 + 16);

  @override
  Widget build(BuildContext context) {
    final style = _style(context);
    if (isLive) return Text(liveLabel, style: style);
    final elapsedSize = _measure(context, elapsed);
    final totalSize = _measure(context, total);
    Widget label(String value, String key) =>
        Text(value, key: ValueKey(key), style: style, maxLines: 1);
    final bar = SizedBox(height: 28, child: seekBar);
    return LayoutBuilder(
      builder: (context, constraints) {
        final inline =
            constraints.maxWidth >=
            elapsedSize.width + totalSize.width + 16 + 120;
        if (inline) {
          return Row(
            key: const ValueKey('desktopProgressInline'),
            children: [
              label(elapsed, 'desktopPlayerElapsed'),
              const SizedBox(width: 8),
              Expanded(child: bar),
              const SizedBox(width: 8),
              label(total, 'desktopPlayerTotal'),
            ],
          );
        }
        return Column(
          key: const ValueKey('desktopProgressStacked'),
          mainAxisSize: MainAxisSize.min,
          children: [
            bar,
            if (elapsedSize.width + totalSize.width + 8 <= constraints.maxWidth)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  label(elapsed, 'desktopPlayerElapsed'),
                  label(total, 'desktopPlayerTotal'),
                ],
              )
            else ...[
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: label(elapsed, 'desktopPlayerElapsed'),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: label(total, 'desktopPlayerTotal'),
              ),
            ],
          ],
        );
      },
    );
  }
}
