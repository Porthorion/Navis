import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/trending_detail_screen.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/features/library/presentation/ranked_virtual_playlist_content.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';

import '../../../../helpers/test_theme.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    FutureOr<List<ResolvedArtistTopTrack>> Function(Ref ref) tracks,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          homeTrendingProvider.overrideWith(tracks),
          songDownloadStateProvider.overrideWith(
            (ref, songId) => SongDownloadState.none,
          ),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TrendingDetailScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('the route lives under Library', () {
    expect(AppRoutes.trending, '/library/trending');
  });

  testWidgets('lists the playable chart songs in the ranked layout', (
    tester,
  ) async {
    await pump(
      tester,
      (ref) => <ResolvedArtistTopTrack>[
        for (final rank in <int>[1, 4, 9])
          ResolvedArtistTopTrack(
            rank: rank,
            title: 'Song $rank',
            artist: 'Artist',
            resolvedSong: Song(id: 's$rank', title: 'Song $rank'),
          ),
      ],
    );
    expect(find.byType(RankedVirtualPlaylistContent), findsOneWidget);
    expect(find.text('Deezer chart • 3 songs'), findsOneWidget);
    for (final rank in <String>['1', '4', '9']) {
      expect(find.text(rank), findsOneWidget);
    }
  });

  testWidgets('says when too few chart songs are playable', (tester) async {
    await pump(tester, (ref) => const <ResolvedArtistTopTrack>[]);
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('No Trending Songs'), findsOneWidget);
  });

  testWidgets('offers a retry when the chart fails', (tester) async {
    await pump(tester, (ref) => throw StateError('offline'));
    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text('Could Not Load Trending'), findsOneWidget);
  });
}
