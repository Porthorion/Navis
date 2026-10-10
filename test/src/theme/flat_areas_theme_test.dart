import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  test('area masks round trip and support immutable edits', () {
    for (var bits = 0; bits <= 7; bits++) {
      final areas = FlatAreas.fromBits(bits);
      expect(areas.bits, bits);
      expect(areas.copyWith(), areas);
      expect(areas.hashCode, FlatAreas.fromBits(bits).hashCode);
      expect(areas.copyWith(surfaces: !areas.surfaces).bits, bits ^ 1);
      expect(areas.copyWith(nowPlaying: !areas.nowPlaying).bits, bits ^ 2);
      expect(areas.copyWith(artworkText: !areas.artworkText).bits, bits ^ 4);
    }
    expect(() => FlatAreas.fromBits(-1), throwsRangeError);
    expect(() => FlatAreas.fromBits(8), throwsRangeError);
  });

  for (final flat in [false, true]) {
    for (var bits = 0; bits <= 7; bits++) {
      test('Flat switch=$flat mask=$bits controls independent areas', () {
        final areas = FlatAreas.fromBits(bits);
        final data = NavisColorStyleData(
          style: NavisColorStyle.neutral,
          dark: true,
          flat: flat,
          flatAreas: areas,
        );
        expect(data.flat, flat);
        expect(data.flatSurfaces, flat && bits & 1 != 0);
        expect(data.flatNowPlaying, flat && bits & 2 != 0);
        expect(data.flatArtworkText, flat && bits & 4 != 0);
        expect(data.copyWith(dark: false).flatAreas, areas);
        expect(
          data.copyWith(flatAreas: const FlatAreas()).flatNowPlaying,
          flat,
        );
        expect(
          data.lerp(data.copyWith(flatAreas: const FlatAreas()), 1).flatAreas,
          const FlatAreas(),
        );
        expect(
          nowPlayingShowsArtworkLayer(
            background: NowPlayingBackground.artwork,
            flat: data.flatNowPlaying,
            hasImage: true,
          ),
          !data.flatNowPlaying,
        );
      });
    }
  }

  for (final builder in [buildLightTheme, buildDarkTheme, buildOledTheme]) {
    test('$builder uses the surfaces area for theme shadows', () {
      final normal = builder(Colors.blue);
      final all = builder(Colors.blue, flat: true);
      expect(all.shadowColor, Colors.transparent);
      expect(all.colorScheme.shadow, Colors.transparent);
      final partial = builder(
        Colors.blue,
        flat: true,
        flatAreas: const FlatAreas(surfaces: false),
      );
      expect(partial.shadowColor, normal.shadowColor);
      expect(partial.colorScheme.shadow, normal.colorScheme.shadow);
      final style = partial.extension<NavisColorStyleData>()!;
      expect(style.flat, isTrue);
      expect(style.flatSurfaces, isFalse);
      expect(style.flatNowPlaying, isTrue);
      expect(style.flatArtworkText, isTrue);
      expect(all.extension<NavisColorStyleData>()!.flatAreas.bits, 7);
    });
  }

  test('theme cache distinguishes masks and reuses equal area values', () {
    final cache = NavisThemeCache();
    ThemeData resolve(FlatAreas areas) => cache.resolve(
      seed: Colors.blue,
      brightness: Brightness.dark,
      oled: false,
      style: NavisColorStyle.neutral,
      flat: true,
      flatAreas: areas,
      corners: NavisCornerStyle.rounded,
    );
    final all = resolve(const FlatAreas());
    final player = resolve(FlatAreas.fromBits(2));
    expect(player, isNot(same(all)));
    expect(resolve(FlatAreas.fromBits(2)), same(player));
    expect(resolve(FlatAreas.fromBits(7)), same(all));
  });
}
