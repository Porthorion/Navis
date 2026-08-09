import 'package:flutter/material.dart';

/// A desktop volume slider with a floating percentage tooltip that tracks the
/// thumb position while the user is dragging.
///
/// The tooltip is a small rounded pill (e.g. "72 %") floating above the slider
/// thumb. It appears on interaction and fades out smoothly when the user
/// releases the slider.
class DesktopVolumeSlider extends StatefulWidget {
  const DesktopVolumeSlider({
    super.key,
    required this.volume,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onMuteToggle,
    required this.semanticLabel,
    required this.muteTooltip,
    required this.unmuteTooltip,
    this.compact = false,
    this.expanded = false,
  });

  /// Current volume in the range [0, 1].
  final double volume;

  /// Fires continuously as the slider is dragged.
  final ValueChanged<double> onChanged;

  /// Fires once when the user finishes dragging.
  final ValueChanged<double> onChangeEnd;

  /// Fires when the mute/unmute icon button is tapped.
  final VoidCallback onMuteToggle;

  final String semanticLabel;
  final String muteTooltip;
  final String unmuteTooltip;

  /// When true, uses smaller sizing (for now-playing transport).
  final bool compact;

  /// When true, fills the available width instead of using a fixed preset.
  final bool expanded;

  @override
  State<DesktopVolumeSlider> createState() => _DesktopVolumeSliderState();
}

class _DesktopVolumeSliderState extends State<DesktopVolumeSlider>
    with SingleTickerProviderStateMixin {
  bool _isDragging = false;
  bool _isHovering = false;
  double _dragValue = 0;

  late final AnimationController _tooltipFade;

  @override
  void initState() {
    super.initState();
    _tooltipFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
  }

  @override
  void dispose() {
    _tooltipFade.dispose();
    super.dispose();
  }

  void _onChangeStart(double value) {
    setState(() {
      _isDragging = true;
      _dragValue = value;
    });
    _tooltipFade.forward();
  }

  void _onChanged(double value) {
    setState(() {
      _dragValue = value;
    });
    widget.onChanged(value);
  }

  void _onChangeEnd(double value) {
    widget.onChangeEnd(value);
    setState(() => _isDragging = false);
    _tooltipFade.reverse();
  }

  void _onEnter() {
    if (!_isHovering) {
      setState(() => _isHovering = true);
    }
  }

  void _onExit() {
    if (_isHovering) {
      setState(() => _isHovering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compact = widget.compact;
    final displayVolume = _isDragging ? _dragValue : widget.volume;
    final percent = (displayVolume * 100).round();
    final trackHeight = compact ? 2.4 : 2.8;
    final thumbRadius = compact ? 4.8 : 5.5;
    final overlayRadius = compact ? 10.0 : 12.0;
    final sliderWidth = compact ? 140.0 : 188.0;

    final control = Row(
      children: <Widget>[
        IconButton(
          iconSize: compact ? 18 : 20,
          visualDensity: VisualDensity.compact,
          tooltip: widget.volume <= 0.001
              ? widget.unmuteTooltip
              : widget.muteTooltip,
          onPressed: widget.onMuteToggle,
          icon: Icon(
            widget.volume <= 0.01
                ? Icons.volume_off_rounded
                : (widget.volume < 0.5
                      ? Icons.volume_down_rounded
                      : Icons.volume_up_rounded),
            color: colors.onSurfaceVariant,
          ),
        ),
        SizedBox(width: compact ? 0 : 2),
        Expanded(
          child: MouseRegion(
            onEnter: (_) => _onEnter(),
            onExit: (_) => _onExit(),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final trackWidth = constraints.maxWidth;
                // Horizontal offset of the thumb center relative to the track.
                final thumbOffset = trackWidth * displayVolume;
                final showTooltip = _isDragging || _isHovering;

                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: trackHeight,
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: thumbRadius,
                        ),
                        overlayShape: RoundSliderOverlayShape(
                          overlayRadius: overlayRadius,
                        ),
                      ),
                      child: Semantics(
                        label: widget.semanticLabel,
                        value: '$percent%',
                        child: Slider(
                          value: displayVolume,
                          min: 0,
                          max: 1,
                          semanticFormatterCallback: (value) =>
                              '${(value * 100).round()}%',
                          onChangeStart: _onChangeStart,
                          onChanged: _onChanged,
                          onChangeEnd: _onChangeEnd,
                        ),
                      ),
                    ),
                    // Floating percentage tooltip.
                    if (showTooltip)
                      Positioned(
                        left: thumbOffset - 16,
                        top: -28,
                        child: IgnorePointer(
                          child: FadeTransition(
                            opacity: _isDragging
                                ? const AlwaysStoppedAnimation(1)
                                : _tooltipFade,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colors.inverseSurface,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '$percent%',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: colors.onInverseSurface,
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
    if (widget.expanded) {
      return control;
    }
    return SizedBox(
      width: sliderWidth,
      child: control,
    );
  }
}
