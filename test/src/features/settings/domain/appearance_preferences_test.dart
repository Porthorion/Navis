import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';

void main() {
  test('background storage keys round trip and unknown values use tinted', () {
    for (final background in NowPlayingBackground.values) {
      expect(NowPlayingBackground.parse(background.storageKey), background);
    }
    expect(NowPlayingBackground.parse(null), NowPlayingBackground.tinted);
    expect(NowPlayingBackground.parse(''), NowPlayingBackground.tinted);
    expect(NowPlayingBackground.parse('unknown'), NowPlayingBackground.tinted);
  });

  test(
    'density storage keys round trip and unknown values use comfortable',
    () {
      for (final density in NavisDensity.values) {
        expect(NavisDensity.parse(density.storageKey), density);
      }
      expect(NavisDensity.parse(null), NavisDensity.comfortable);
      expect(NavisDensity.parse(''), NavisDensity.comfortable);
      expect(NavisDensity.parse('unknown'), NavisDensity.comfortable);
    },
  );

  test('model copy preserves background and supports the legacy tint flag', () {
    const defaults = AppSettingsModel.defaults();
    final artwork = defaults.copyWith(
      nowPlayingBackground: NowPlayingBackground.artwork,
      density: NavisDensity.compact,
    );
    expect(artwork.artTintedNowPlaying, isTrue);
    expect(artwork.homeDensity, 'compact');
    expect(
      artwork.copyWith(themeMode: 'light').nowPlayingBackground,
      NowPlayingBackground.artwork,
    );
    expect(
      artwork.copyWith(artTintedNowPlaying: false).nowPlayingBackground,
      NowPlayingBackground.plain,
    );
    expect(
      artwork.copyWith(artTintedNowPlaying: true).nowPlayingBackground,
      NowPlayingBackground.tinted,
    );
    expect(
      artwork
          .copyWith(
            artTintedNowPlaying: false,
            nowPlayingBackground: NowPlayingBackground.artwork,
          )
          .nowPlayingBackground,
      NowPlayingBackground.artwork,
    );
  });
}
