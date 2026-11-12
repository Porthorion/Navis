import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/player/presentation/now_playing_backdrop.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';

const _tint = Color(0xFFD32F2F);
const _cover = Color(0xFF3F7F6F);

NowPlayingPublishedBackdrop _backdrop({
  bool image = false,
  Color? tint,
  Color? average,
}) => NowPlayingPublishedBackdrop(
  owner: Object(),
  imageKey: image ? 'k' : null,
  image: image ? MemoryImage(Uint8List(0)) : null,
  coverAverage: average,
  useCoverAverage: average != null,
  tintColor: tint,
);

ThemeData _theme({bool oled = false, bool flat = false}) => oled
    ? buildOledTheme(_cover, style: NavisColorStyle.pastel, flat: flat)
    : buildDarkTheme(_cover, style: NavisColorStyle.pastel, flat: flat);

void main() {
  group('resolveNowPlayingLayer', () {
    const t = NowPlayingBackground.tinted;
    const a = NowPlayingBackground.artwork;
    const p = NowPlayingBackground.plain;
    final both = _backdrop(image: true, tint: _tint, average: _cover);
    final imageOnly = _backdrop(image: true, average: _cover);
    final tintOnly = _backdrop(tint: _tint);

    test('plain is always plain', () {
      for (final b in [null, both, tintOnly]) {
        expect(resolveNowPlayingLayer(p, b, flat: false), p);
      }
    });

    test('tinted needs a tint colour', () {
      expect(resolveNowPlayingLayer(t, both, flat: false), t);
      expect(resolveNowPlayingLayer(t, tintOnly, flat: true), t);
      expect(resolveNowPlayingLayer(t, imageOnly, flat: false), p);
      expect(resolveNowPlayingLayer(t, null, flat: false), p);
    });

    test('artwork needs an image and non-Flat, else falls back to tinted', () {
      expect(resolveNowPlayingLayer(a, both, flat: false), a);
      expect(resolveNowPlayingLayer(a, imageOnly, flat: false), a);
      expect(resolveNowPlayingLayer(a, both, flat: true), t);
      expect(resolveNowPlayingLayer(a, tintOnly, flat: false), t);
      expect(resolveNowPlayingLayer(a, imageOnly, flat: true), p);
      expect(resolveNowPlayingLayer(a, null, flat: false), p);
    });
  });

  group('nowPlayingMenuFill', () {
    test('plain has no fill', () {
      final theme = _theme();
      expect(
        nowPlayingMenuFill(
          layer: NowPlayingBackground.plain,
          backdrop: _backdrop(tint: _tint),
          scheme: theme.colorScheme,
          style: theme.extension<NavisColorStyleData>()!,
        ),
        isNull,
      );
    });

    test('tinted equals the Flat Now Playing colour', () {
      final theme = _theme(flat: true);
      final style = theme.extension<NavisColorStyleData>()!;
      final surface = theme.colorScheme.surface;
      final expected = nowPlayingSurfaceDecoration(
        tintColor: _tint,
        colorStyle: style,
        surfaceColor: surface,
      ).color;
      final fill = nowPlayingMenuFill(
        layer: NowPlayingBackground.tinted,
        backdrop: _backdrop(tint: _tint),
        scheme: theme.colorScheme,
        style: style,
      );
      expect(fill, expected);
      expect(fill, isNot(surface));
    });

    test('tinted under OLED + Flat stays on the theme', () {
      final theme = _theme(oled: true, flat: true);
      expect(
        nowPlayingMenuFill(
          layer: NowPlayingBackground.tinted,
          backdrop: _backdrop(tint: _tint),
          scheme: theme.colorScheme,
          style: theme.extension<NavisColorStyleData>()!,
        ),
        isNull,
      );
    });

    test('artwork is opaque and keeps text readable', () {
      for (final theme in [_theme(), _theme(oled: true)]) {
        for (final average in const [
          Color(0xFFFFEB3B),
          Color(0xFFFFFFFF),
          Color(0xFF000000),
          _cover,
        ]) {
          final scheme = theme.colorScheme;
          final fill = nowPlayingMenuFill(
            layer: NowPlayingBackground.artwork,
            backdrop: _backdrop(image: true, average: average),
            scheme: scheme,
            style: theme.extension<NavisColorStyleData>()!,
          )!;
          expect(fill.a, 1);
          expect(
            captionContrast(scheme.onSurface, fill),
            greaterThanOrEqualTo(kNowPlayingArtworkTargetContrast - 0.2),
            reason: '$average',
          );
        }
      }
    });

    test('artwork without a cover average uses the tint, else the theme', () {
      final theme = _theme();
      final style = theme.extension<NavisColorStyleData>()!;
      Color? fill(NowPlayingPublishedBackdrop b) => nowPlayingMenuFill(
        layer: NowPlayingBackground.artwork,
        backdrop: b,
        scheme: theme.colorScheme,
        style: style,
      );
      expect(fill(_backdrop(image: true, tint: _tint)), isNotNull);
      expect(fill(_backdrop(image: true)), isNull);
    });
  });
}
