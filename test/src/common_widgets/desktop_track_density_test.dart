import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/desktop_song_actions.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
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

/// The desktop album page's row: wide, no artwork, DesktopSongActions.
Future<double> _rowHeight(WidgetTester tester, NavisDensity density) async {
  setAdaptiveTestViewport(tester, const Size(1200, 800));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerStateProvider.overrideWithValue(const PlaybackSnapshot.idle()),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        songStarredProvider.overrideWith((ref, id) => Stream.value(false)),
        songDownloadStateProvider.overrideWith(
          (ref, id) => SongDownloadState.none,
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NavisDensityScope(
          density: density,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: TrackListTile(
                song: _song,
                showAlbumColumn: false,
                horizontalTitleGap: 6,
                trailing: DesktopSongActions(song: _song),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.getSize(find.byType(AdaptiveTrackRow)).height;
}

void main() {
  testWidgets('compact density tightens the desktop album track row', (
    tester,
  ) async {
    final comfortable = await _rowHeight(tester, NavisDensity.comfortable);
    final compact = await _rowHeight(tester, NavisDensity.compact);
    expect(compact, lessThan(comfortable), reason: '$compact vs $comfortable');
  });
}
