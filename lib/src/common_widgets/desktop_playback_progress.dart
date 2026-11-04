import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/routing/desktop_layout.dart';

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

  /// Narrowest control rail the persistent player bar gives the seek bar: an
  /// 800 px window (the smallest Desktop View) minus the metadata and action
  /// regions. Times that cannot sit beside the seek bar there stack under it.
  static const double _narrowestRailWidth = 370;

  /// Transport button height in the short band.
  static const double shortTransportExtent = 36;

  /// Player bar height for a window height band. The tall band keeps the
  /// original sizing (scaled labels can increase it); shorter bands use a fixed
  /// height that grows only when the labels at the current text scale no longer
  /// fit beside the seek bar.
  static double playerHeight(
    BuildContext context,
    DesktopHeightClass heightClass,
  ) {
    final label = _measure(context, '00:00:00');
    if (heightClass == DesktopHeightClass.tall) {
      return math.max(116, label.height * 2 + 28 + 44 + 16);
    }
    final short = heightClass == DesktopHeightClass.short;
    final stackedRows = label.width * 2 + 16 + 120 <= _narrowestRailWidth
        ? 0
        : (label.width * 2 + 8 <= _narrowestRailWidth ? 1 : 2);
    // Seek bar (+ stacked labels) + gap + transport row + vertical insets.
    final controls =
        28 +
        stackedRows * label.height +
        1 +
        (short ? shortTransportExtent : 44) +
        8;
    // Title, artist and a remote-source line at the current text scale, plus
    // paddings.
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    double line(TextStyle? style) =>
        scaler.scale(style?.fontSize ?? 14) * (style?.height ?? 1.3);
    final metadata = line(text.bodyMedium) + line(text.bodySmall) * 2 + 8 + 8;
    return math.max(short ? 84 : 100, math.max(controls, metadata));
  }

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
