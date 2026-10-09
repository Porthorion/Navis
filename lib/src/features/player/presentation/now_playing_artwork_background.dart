import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// Width in pixels the cover is decoded at for the Artwork background. The
/// image is blurred beyond recognition, so a thumbnail is plenty.
const int kNowPlayingArtworkDecodeWidth = 96;

/// Blur radius of the Artwork background, in logical pixels.
const double kNowPlayingArtworkBlurSigma = 32;

/// The image is drawn this much larger than the screen so the blur never
/// shows transparent edges.
const double kNowPlayingArtworkOverscale = 1.2;

/// Contrast the adaptive veil aims for: the WCAG minimum plus a margin for
/// bright areas the average hides.
const double kNowPlayingArtworkTargetContrast = kCaptionMinContrast + 0.5;

/// Extra veil alpha over the bottom fifth, calming the controls area.
const double kNowPlayingArtworkBottomVeilAlpha = 0.15;

/// The lightest veil that keeps [onSurface] and [accent] (the accent-coloured
/// title) readable over a cover averaging [average], within [colorStyle]'s
/// alpha range. With no [average] it is the fixed veil.
Color nowPlayingAdaptiveVeil({
  required NavisColorStyleData colorStyle,
  required Color surface,
  required Color onSurface,
  required Color? average,
  Color? accent,
}) {
  if (average == null) return colorStyle.nowPlayingArtworkVeil(surface);
  final base = colorStyle.nowPlayingArtworkVeilBase(surface);
  final (min, max) = colorStyle.nowPlayingArtworkVeilRange;
  for (var alpha = min; alpha < max; alpha += 0.01) {
    final veiled = Color.alphaBlend(base.withValues(alpha: alpha), average);
    if (captionContrast(onSurface, veiled) >=
            kNowPlayingArtworkTargetContrast &&
        (accent == null ||
            captionContrast(accent, veiled) >=
                kNowPlayingArtworkTargetContrast)) {
      return base.withValues(alpha: alpha);
    }
  }
  return base.withValues(alpha: max);
}

/// Average colour of [image], read from its (thumbnail-sized) pixels.
Future<Color?> averageImageColor(ui.Image image) async {
  final data = await image.toByteData();
  if (data == null || data.lengthInBytes < 4) return null;
  var r = 0, g = 0, b = 0;
  final count = data.lengthInBytes ~/ 4;
  for (var i = 0; i < count; i++) {
    r += data.getUint8(i * 4);
    g += data.getUint8(i * 4 + 1);
    b += data.getUint8(i * 4 + 2);
  }
  return Color.fromARGB(255, r ~/ count, g ~/ count, b ~/ count);
}

/// Blurred, veiled cover behind Now Playing (the Artwork background).
///
/// The caller passes a small decoded [image] identified by [imageKey]. A new
/// image replaces the shown one only once it has decoded, with a crossfade of
/// [fadeDuration], so track changes never flash through the plain surface. A
/// null [image] keeps whatever is shown. The veil keeps text legible; the
/// bottom gets a gentle extra veil to calm the controls.
class NowPlayingArtworkBackground extends StatefulWidget {
  const new({
    required this.imageKey,
    required this.image,
    required this.colorStyle,
    required this.surfaceColor,
    required this.onSurfaceColor,
    required this.fadeDuration,
    this.accentColor,
    super.key,
  });

  /// Identity of [image] (cover id or art URL).
  final String? imageKey;

  /// Small decoded cover, or null while there is none.
  final ImageProvider<Object>? image;

  /// Style that picks the veil colour and its alpha range.
  final NavisColorStyleData colorStyle;

  /// Theme surface; the light veil washes the cover out with it.
  final Color surfaceColor;

  /// Text colour the veil must keep readable.
  final Color onSurfaceColor;

  /// Accent text colour (the track title) the veil must also keep readable.
  final Color? accentColor;

  /// Crossfade between covers; zero under reduced motion.
  final Duration fadeDuration;

  @override
  State<NowPlayingArtworkBackground> createState() =>
      _NowPlayingArtworkBackgroundState();
}

class _NowPlayingArtworkBackgroundState
    extends State<NowPlayingArtworkBackground> {
  String? _shownKey;
  ImageProvider<Object>? _shown;
  Color? _shownAverage;
  String? _pendingKey;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(NowPlayingArtworkBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final key = widget.imageKey;
    final image = widget.image;
    if (key == null || image == null) return;
    if (key == _shownKey) {
      _shown = image;
      return;
    }
    if (key == _pendingKey) return;
    _stopListening();
    _pendingKey = key;
    final stream = image.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!mounted || _pendingKey != key) return;
        unawaited(() async {
          Color? average;
          try {
            average = await averageImageColor(info.image);
          } on Object {
            average = null;
          }
          if (!mounted || _pendingKey != key) return;
          setState(() {
            _shownKey = key;
            _shown = image;
            _shownAverage = average;
            _pendingKey = null;
          });
        }());
      },
      onError: (_, _) {
        stream.removeListener(listener);
        if (_pendingKey == key) _pendingKey = null;
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _stopListening() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
    _pendingKey = null;
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    final veil = nowPlayingAdaptiveVeil(
      colorStyle: widget.colorStyle,
      surface: widget.surfaceColor,
      onSurface: widget.onSurfaceColor,
      accent: widget.accentColor,
      average: _shownAverage,
    );
    final bottom = widget.colorStyle.nowPlayingArtworkVeilBase(
      widget.surfaceColor,
    );
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          AnimatedSwitcher(
            duration: widget.fadeDuration,
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.expand,
              children: <Widget>[...previous, ?current],
            ),
            child: ImageFiltered(
              key: ValueKey<String?>(_shownKey),
              imageFilter: ui.ImageFilter.blur(
                sigmaX: kNowPlayingArtworkBlurSigma,
                sigmaY: kNowPlayingArtworkBlurSigma,
                tileMode: TileMode.clamp,
              ),
              child: SizedBox.expand(
                child: Transform.scale(
                  scale: kNowPlayingArtworkOverscale,
                  child: Image(
                    image: shown,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.low,
                    gaplessPlayback: true,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ),
          ),
          ColoredBox(color: veil),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  bottom.withValues(alpha: 0),
                  bottom.withValues(alpha: kNowPlayingArtworkBottomVeilAlpha),
                ],
                stops: const <double>[0.8, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
