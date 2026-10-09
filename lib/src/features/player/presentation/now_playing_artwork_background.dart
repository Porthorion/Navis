import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// Width in pixels the cover is decoded at for the Artwork background. The
/// image is blurred beyond recognition, so a thumbnail is plenty.
const int kNowPlayingArtworkDecodeWidth = 96;

/// Blur radius of the Artwork background, in logical pixels.
const double kNowPlayingArtworkBlurSigma = 32;

/// Blurred, veiled cover behind Now Playing (the Artwork background).
///
/// The caller passes a small decoded [image] identified by [imageKey]. A new
/// image replaces the shown one only once it has decoded, with a crossfade of
/// [fadeDuration], so track changes never flash through the plain surface. A
/// null [image] keeps whatever is shown. The veil keeps text legible; the
/// bottom fades into [surfaceColor] like the tinted gradient.
class NowPlayingArtworkBackground extends StatefulWidget {
  const new({
    required this.imageKey,
    required this.image,
    required this.veil,
    required this.surfaceColor,
    required this.fadeDuration,
    super.key,
  });

  /// Identity of [image] (cover id or art URL).
  final String? imageKey;

  /// Small decoded cover, or null while there is none.
  final ImageProvider<Object>? image;

  /// Translucent colour over the blurred cover.
  final Color veil;

  /// Surface the bottom fades into.
  final Color surfaceColor;

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
      (_, _) {
        stream.removeListener(listener);
        if (!mounted || _pendingKey != key) return;
        setState(() {
          _shownKey = key;
          _shown = image;
          _pendingKey = null;
        });
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
                tileMode: TileMode.mirror,
              ),
              child: SizedBox.expand(
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
          ColoredBox(color: widget.veil),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  widget.surfaceColor.withValues(alpha: 0),
                  widget.surfaceColor,
                ],
                stops: const <double>[0, 0.7],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
