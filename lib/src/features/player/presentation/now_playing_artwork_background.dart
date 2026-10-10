import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// Width in pixels the cover is decoded at for the Artwork background. The
/// image is blurred beyond recognition, so a thumbnail is plenty.
const int kNowPlayingArtworkDecodeWidth = 96;

/// Blur sigma in thumbnail pixels (about 40 logical pixels on a phone).
const double kNowPlayingArtworkBlurSigma = 5;

/// Contrast the adaptive veil aims for: the WCAG minimum plus a margin for
/// bright areas the average hides.
const double kNowPlayingArtworkTargetContrast = kCaptionMinContrast + 0.5;

/// Extra veil alpha over the bottom fifth, calming the controls area.
const double kNowPlayingArtworkBottomVeilAlpha = 0.15;

/// The lightest veil that keeps [onSurface], [onSurfaceVariant] (secondary
/// lines such as the format line) and [accent] (the accent-coloured title)
/// readable over a cover averaging [average], within [colorStyle]'s
/// alpha range. With no [average] it is the fixed veil. [minAlpha] raises
/// the floor for views where text runs across the whole cover (lyrics).
Color nowPlayingAdaptiveVeil({
  required NavisColorStyleData colorStyle,
  required Color surface,
  required Color onSurface,
  required Color? average,
  Color? accent,
  Color? onSurfaceVariant,
  double? minAlpha,
}) {
  final base = colorStyle.nowPlayingArtworkVeilBase(surface);
  final (rangeMin, max) = colorStyle.nowPlayingArtworkVeilRange;
  final min = minAlpha == null ? rangeMin : math.max(rangeMin, minAlpha);
  if (average == null) {
    final fixed = colorStyle.nowPlayingArtworkVeil(surface);
    return fixed.a >= min ? fixed : base.withValues(alpha: min);
  }
  for (var alpha = min; alpha < max; alpha += 0.01) {
    final veiled = Color.alphaBlend(base.withValues(alpha: alpha), average);
    if (captionContrast(onSurface, veiled) >=
            kNowPlayingArtworkTargetContrast &&
        (onSurfaceVariant == null ||
            captionContrast(onSurfaceVariant, veiled) >=
                kNowPlayingArtworkTargetContrast) &&
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
  var r = 0;
  var g = 0;
  var b = 0;
  final count = data.lengthInBytes ~/ 4;
  for (var i = 0; i < count; i++) {
    r += data.getUint8(i * 4);
    g += data.getUint8(i * 4 + 1);
    b += data.getUint8(i * 4 + 2);
  }
  return Color.fromARGB(255, r ~/ count, g ~/ count, b ~/ count);
}

/// Whether the Artwork background draws its blurred cover. Flat has no blur
/// (it falls back to the solid art colour) and a missing cover falls back to
/// the tinted look.
bool nowPlayingShowsArtworkLayer({
  required NowPlayingBackground background,
  required bool flat,
  required bool hasImage,
}) => background == NowPlayingBackground.artwork && !flat && hasImage;

/// Highest HCT tone of the art-tinted gradient's top colour in OLED.
const double kNowPlayingOledMaxTintTone = 10;

/// Background of the Now Playing surface.
///
/// No [tintColor] (art tint off or no art yet): plain [surfaceColor]. With a
/// tint: the style-adapted art colour fading into the surface, or under Flat
/// one solid colour, the adapted tint at the style's alpha composited over
/// the surface.
BoxDecoration nowPlayingSurfaceDecoration({
  required Color? tintColor,
  required NavisColorStyleData colorStyle,
  required Color surfaceColor,
}) {
  // OLED + Flat stays pure black: a solid tint would lift the whole screen
  // off black, which defeats OLED. Non-flat OLED keeps its gradient.
  if (tintColor == null || (colorStyle.flatNowPlaying && colorStyle.oled)) {
    return BoxDecoration(color: surfaceColor);
  }
  var adaptedTint = colorStyle.adaptArtColor(tintColor);
  if (colorStyle.oled) {
    // OLED keeps the gradient's top near black: cap its HCT tone.
    final hctTint = Hct.fromInt(adaptedTint.toARGB32());
    if (hctTint.tone > kNowPlayingOledMaxTintTone) {
      adaptedTint = Color(
        Hct.from(
          hctTint.hue,
          hctTint.chroma,
          kNowPlayingOledMaxTintTone,
        ).toInt(),
      );
    }
  }
  final tint = adaptedTint.withValues(alpha: colorStyle.nowPlayingTintAlpha);
  if (colorStyle.flatNowPlaying) {
    return BoxDecoration(color: Color.alphaBlend(tint, surfaceColor));
  }
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[tint, surfaceColor],
      stops: const <double>[0, 0.7],
    ),
  );
}

/// Blurred, veiled cover behind Now Playing (the Artwork background).
///
/// The caller passes a thumbnail provider [image] identified by [imageKey]. A new
/// image replaces the shown one only once it has decoded, with a crossfade of
/// [fadeDuration], so track changes never flash through the plain surface. A
/// null [image] keeps whatever is shown. The veil keeps text legible; the
/// bottom gets a gentle extra veil to calm the controls.
class NowPlayingArtworkBackground extends ConsumerStatefulWidget {
  const new({
    required this.imageKey,
    required this.image,
    required this.colorStyle,
    required this.surfaceColor,
    required this.onSurfaceColor,
    required this.fadeDuration,
    this.accentColor,
    this.minVeilAlpha,
    this.coverAverage,
    this.useCoverAverage = false,
    this.onAvailabilityChanged,
    this.onSurfaceVariantColor,
    super.key,
  });

  /// Reports async preparation availability so parents can select a fallback.
  final void Function(String key, {required bool available})?
  onAvailabilityChanged;

  /// Identity of [image] (cover id or art URL).
  final String? imageKey;

  /// Thumbnail cover source, or null while there is none.
  final ImageProvider<Object>? image;

  /// Shared colour-field average for server cover art. URL art samples pixels.
  final Color? coverAverage;
  final bool useCoverAverage;

  /// Style that picks the veil colour and its alpha range.
  final NavisColorStyleData colorStyle;

  /// Theme surface; the light veil washes the cover out with it.
  final Color surfaceColor;

  /// Text colour the veil must keep readable.
  final Color onSurfaceColor;

  /// Secondary text colour (artist, format line) the veil must also keep
  /// readable.
  final Color? onSurfaceVariantColor;

  /// Accent text colour (the track title) the veil must also keep readable.
  final Color? accentColor;

  /// Floor for the veil alpha, for views with text across the whole cover.
  final double? minVeilAlpha;

  /// Crossfade between covers; zero under reduced motion.
  final Duration fadeDuration;

  @override
  ConsumerState<NowPlayingArtworkBackground> createState() =>
      _NowPlayingArtworkBackgroundState();
}

class _NowPlayingArtworkBackgroundState
    extends ConsumerState<NowPlayingArtworkBackground> {
  final Set<String> _failedKeys = <String>{};
  String? _shownKey;
  BlurredNowPlayingArtwork? _shown;
  Color? _shownAverage;
  String? _pendingKey;

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
    if (key == null || image == null || _failedKeys.contains(key)) return;
    if (key == _shownKey) {
      if (widget.useCoverAverage) _shownAverage = widget.coverAverage;
      _pendingKey = null;
      return;
    }
    if (key == _pendingKey) return;
    _pendingKey = key;
    final cache = ref.read(nowPlayingArtworkCacheProvider);
    final configuration = createLocalImageConfiguration(context);
    unawaited(() async {
      try {
        final prepared = await cache.acquire(key, image, configuration);
        if (!mounted || _pendingKey != key) {
          prepared.image.dispose();
          return;
        }
        final previous = _shown;
        setState(() {
          _shownKey = key;
          _shown = prepared;
          _shownAverage = widget.useCoverAverage
              ? widget.coverAverage
              : prepared.average;
          _pendingKey = null;
        });
        previous?.image.dispose();
        widget.onAvailabilityChanged?.call(key, available: true);
      } on Object {
        if (!mounted || _pendingKey != key) return;
        final previous = _shown;
        setState(() {
          _pendingKey = null;
          _failedKeys.add(key);
          _shown = null;
          _shownKey = null;
          _shownAverage = null;
        });
        previous?.image.dispose();
        widget.onAvailabilityChanged?.call(key, available: false);
      }
    }());
  }

  @override
  void dispose() {
    _shown?.image.dispose();
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
      onSurfaceVariant: widget.onSurfaceVariantColor,
      average: _shownAverage,
      minAlpha: widget.minVeilAlpha,
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
            child: _StaticArtworkImage(
              key: ValueKey<String?>(_shownKey),
              image: shown.image,
            ),
          ),
          AnimatedContainer(
            duration: MotionPolicy.of(context).tint,
            curve: Curves.easeInOutCubic,
            color: veil,
          ),
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

// Each switcher child retains its own handle until its fade has finished.
class _StaticArtworkImage extends StatefulWidget {
  const new({required this.image, super.key});
  final ui.Image image;

  @override
  State<_StaticArtworkImage> createState() => _StaticArtworkImageState();
}

class _StaticArtworkImageState extends State<_StaticArtworkImage> {
  late ui.Image _image;

  @override
  void initState() {
    super.initState();
    _image = widget.image.clone();
  }

  @override
  void dispose() {
    _image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawImage(
    image: _image,
    fit: BoxFit.cover,
    filterQuality: FilterQuality.medium,
  );
}

/// A prepared thumbnail. Handles returned by the cache belong to the caller.
class BlurredNowPlayingArtwork {
  const new(this.image, this.average);
  final ui.Image image;
  final Color? average;

  BlurredNowPlayingArtwork _clone() =>
      BlurredNowPlayingArtwork(image.clone(), average);
}

class _PendingArtwork {
  new(this.future);
  final Future<BlurredNowPlayingArtwork> future;
  int users = 0;
}

/// Keeps four prepared covers and coalesces concurrent decodes/blur renders.
/// Eviction releases the cache's handle; mounted layers retain their clones.
class NowPlayingArtworkCache {
  new({this.capacity = 4});
  final int capacity;
  final _entries = <String, BlurredNowPlayingArtwork>{};
  final _pending = <String, _PendingArtwork>{};
  final _cancelLoads = <void Function()>{};
  bool _disposed = false;
  int _renders = 0;
  int _hits = 0;

  @visibleForTesting
  int get debugRenderCount => _renders;
  @visibleForTesting
  int get debugHitCount => _hits;
  @visibleForTesting
  ui.Image? debugCachedImage(String key) => _entries[key]?.image;

  Future<BlurredNowPlayingArtwork> acquire(
    String key,
    ImageProvider<Object> source,
    ImageConfiguration configuration,
  ) async {
    if (_disposed) throw StateError('Artwork cache disposed');
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      _hits++;
      return cached._clone();
    }
    var pending = _pending[key];
    if (pending == null) {
      pending = _PendingArtwork(_render(source, configuration));
      _pending[key] = pending;
    } else {
      _hits++;
    }
    pending.users++;
    BlurredNowPlayingArtwork? result;
    try {
      result = await pending.future;
      if (_disposed) throw StateError('Artwork cache disposed');
      return result._clone();
    } finally {
      // The original remains alive until every waiter has acquired its clone,
      // even when many covers finish together or the provider is disposed.
      if (--pending.users == 0) {
        _pending.remove(key);
        if (result != null) {
          if (_disposed) {
            result.image.dispose();
          } else {
            _entries[key] = result;
            while (_entries.length > capacity) {
              _entries.remove(_entries.keys.first)!.image.dispose();
            }
          }
        }
      }
    }
  }

  Future<void> prewarm(
    String key,
    ImageProvider<Object> source,
    ImageConfiguration configuration,
  ) async {
    try {
      final result = await acquire(key, source, configuration);
      result.image.dispose();
    } on Object {
      // Best effort. Visible layers retain their normal tinted fallback.
    }
  }

  Future<BlurredNowPlayingArtwork> _render(
    ImageProvider<Object> source,
    ImageConfiguration configuration,
  ) async {
    final info = await _decode(source, configuration);
    try {
      Color? average;
      try {
        average = await averageImageColor(info.image);
      } on Object {
        average = null;
      }
      if (_disposed) throw StateError('Artwork cache disposed');
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImage(
        info.image,
        Offset.zero,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: kNowPlayingArtworkBlurSigma,
            sigmaY: kNowPlayingArtworkBlurSigma,
            tileMode: TileMode.clamp,
          ),
      );
      final picture = recorder.endRecording();
      try {
        final blurred = await picture.toImage(
          info.image.width,
          info.image.height,
        );
        _renders++;
        return BlurredNowPlayingArtwork(blurred, average);
      } finally {
        picture.dispose();
      }
    } finally {
      info.dispose();
    }
  }

  Future<ImageInfo> _decode(
    ImageProvider<Object> source,
    ImageConfiguration configuration,
  ) {
    final completion = Completer<ImageInfo>();
    final stream = source.resolve(configuration);
    late final ImageStreamListener listener;
    late final void Function() cancel;
    void detach() {
      _cancelLoads.remove(cancel);
      stream.removeListener(listener);
    }

    cancel = () {
      if (completion.isCompleted) return;
      detach();
      completion.completeError(StateError('Artwork cache disposed'));
    };
    listener = ImageStreamListener(
      (info, _) {
        if (completion.isCompleted) {
          info.dispose();
          return;
        }
        detach();
        completion.complete(info);
      },
      onError: (error, stack) {
        if (completion.isCompleted) return;
        detach();
        completion.completeError(error, stack);
      },
    );
    _cancelLoads.add(cancel);
    stream.addListener(listener);
    return completion.future;
  }

  void dispose() {
    _disposed = true;
    for (final cancel in _cancelLoads.toList()) {
      cancel();
    }
    for (final entry in _entries.values) {
      entry.image.dispose();
    }
    _entries.clear();
  }
}

/// App-scoped, keep-alive ownership shared by player, queue and desktop lyrics.
final nowPlayingArtworkCacheProvider = Provider<NowPlayingArtworkCache>((ref) {
  final cache = NowPlayingArtworkCache();
  ref.onDispose(cache.dispose);
  return cache;
});
