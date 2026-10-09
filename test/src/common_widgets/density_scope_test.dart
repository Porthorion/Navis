import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/artist_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_density_scope.dart';

import '../../helpers/adaptive_test_harness.dart';

const _song = SongsTableData(
  id: 'song-1',
  title: 'Song One',
  track: 7,
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
  isProvisional: false,
  isExternal: false,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  NavisDensity? density,
  double width = 700,
}) async {
  setAdaptiveTestViewport(tester, Size(width, 800));
  Widget body = Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  );
  if (density != null) {
    body = NavisDensityScope(density: density, child: body);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerStateProvider.overrideWithValue(const PlaybackSnapshot.idle()),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: body,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  const row = AdaptiveTrackRow(
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    duration: 120,
    leading: SizedBox.shrink(),
  );

  group('NavisDensityScope', () {
    test('compact trims the measurements, comfortable keeps today\'s', () {
      const comfortable = NavisDensityData(NavisDensity.comfortable);
      const compact = NavisDensityData(NavisDensity.compact);
      expect(
        (comfortable.listCover, comfortable.trackRowMinHeight),
        (48.0, 64.0),
      );
      expect(
        comfortable.trackRowPadding,
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      );
      expect((compact.listCover, compact.trackRowMinHeight), (40.0, 52.0));
      expect(
        compact.trackRowPadding,
        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      );
    });

    testWidgets('absent scope reads as comfortable', (tester) async {
      late NavisDensityData data;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            data = NavisDensityScope.of(context);
            return const SizedBox();
          },
        ),
      );
      expect(data, NavisDensityData.comfortable);
    });
  });

  group('AdaptiveTrackRow', () {
    testWidgets('comfortable rows are 64 high', (tester) async {
      await _pump(tester, row);
      expect(tester.getSize(find.byType(AdaptiveTrackRow)).height, 64);
      await _pump(tester, row, density: NavisDensity.comfortable);
      expect(tester.getSize(find.byType(AdaptiveTrackRow)).height, 64);
    });

    testWidgets('compact rows are 52 high', (tester) async {
      await _pump(tester, row, density: NavisDensity.compact);
      expect(tester.getSize(find.byType(AdaptiveTrackRow)).height, 52);
    });

    testWidgets('an explicit minHeight and padding still win', (tester) async {
      await _pump(
        tester,
        const AdaptiveTrackRow(
          title: 'Song',
          minHeight: 48,
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        ),
        density: NavisDensity.compact,
      );
      expect(tester.getSize(find.byType(AdaptiveTrackRow)).height, 48);
    });

    testWidgets('compact keeps a 48 high action reachable', (tester) async {
      await _pump(
        tester,
        const AdaptiveTrackRow(
          title: 'Song',
          artist: 'Artist',
          duration: 120,
          leading: SizedBox.shrink(),
          actions: IconButton(onPressed: null, icon: Icon(Icons.more_horiz)),
        ),
        density: NavisDensity.compact,
      );
      expect(
        tester.getSize(find.byType(IconButton)).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('header and rows share the leading width', (tester) async {
      for (final density in NavisDensity.values) {
        await _pump(
          tester,
          const Column(
            children: [
              SizedBox(
                width: 1000,
                child: AdaptiveTrackHeader(actionExtent: 48),
              ),
              SizedBox(
                width: 1000,
                child: AdaptiveTrackRow(
                  title: 'Song',
                  artist: 'Artist',
                  album: 'Album',
                  duration: 120,
                  actionExtent: 48,
                  leading: SizedBox.shrink(),
                ),
              ),
            ],
          ),
          density: density,
          width: 1000,
        );
        expect(
          tester.getTopLeft(find.text('Title')).dx,
          closeTo(tester.getTopLeft(find.text('Song')).dx, 0.1),
          reason: density.name,
        );
      }
    });
  });

  group('TrackListTile cover', () {
    Size cover(WidgetTester tester) => tester.getSize(
      find.descendant(
        of: find.byType(TrackListTile),
        matching: find.byType(CoverArtImage),
      ),
    );

    testWidgets('comfortable is 48', (tester) async {
      await _pump(tester, const TrackListTile(song: _song, showAlbumArt: true));
      expect(cover(tester), const Size(48, 48));
      expect(tester.getSize(find.byType(TrackListTile)).height, 64);
    });

    testWidgets('compact is 40', (tester) async {
      await _pump(
        tester,
        const TrackListTile(song: _song, showAlbumArt: true),
        density: NavisDensity.compact,
      );
      expect(cover(tester), const Size(40, 40));
      expect(tester.getSize(find.byType(TrackListTile)).height, 52);
    });
  });

  group('ArtistCard', () {
    final artist = ArtistsTableData(
      isProvisional: false,
      isExternal: false,
      id: 'ar-1',
      name: 'Artist',
      albumCount: 2,
    );

    testWidgets('compact rows are shorter than comfortable', (tester) async {
      await _pump(tester, ArtistCard(artist: artist));
      final comfortable = tester.getSize(find.byType(ListTile)).height;
      await _pump(
        tester,
        ArtistCard(artist: artist),
        density: NavisDensity.compact,
      );
      expect(
        tester.getSize(find.byType(ListTile)).height,
        lessThan(comfortable),
      );
      expect(tester.getSize(find.byType(CoverArtImage)), const Size(36, 36));
    });
  });
}
