import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/library/presentation/album_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_detail_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import '../../../../helpers/test_database.dart';

class _DelayedReplaceHandler implements NavisPlaybackHandler {
  _DelayedReplaceHandler({required Completer<void> gate}) : _gate = gate;

  final Completer<void> _gate;
  int replaceCalls = 0;

  @override
  PlaybackSnapshot get snapshot => const PlaybackSnapshot.idle();

  @override
  Stream<PlaybackSnapshot> get snapshotStream =>
      const Stream<PlaybackSnapshot>.empty();

  @override
  Future<void> waitUntilReady() async {}

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
  }) async {
    replaceCalls += 1;
    await _gate.future;
  }

  @override
  Future<void> addToQueue(List<String> songIds) async {}

  @override
  Future<void> playNext(List<String> songIds) async {}

  @override
  Future<void> playFromIndex(int index) async {}

  @override
  Future<void> removeAt(int index) async {}

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) async {}

  @override
  Future<void> clearQueue() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> applyRuntimeSettings() async {}
}

Widget _buildApp({
  required Widget child,
  required NavisDatabase database,
  required List<dynamic> overrides,
}) {
  return ProviderScope(
    overrides: [
      navisDatabaseProvider.overrideWithValue(database),
      serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
      subsonicApiProvider.overrideWith((_) => null),
      ...overrides.cast(),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

Future<void> _disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Drift stream disposal can schedule microtask/zero-delay timers; flush them.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  group('library detail screens', () {
    late NavisDatabase database;

    setUp(() {
      database = createTestDatabase();
    });

    tearDown(() async {
      await database.close();
    });

    testWidgets('artist detail renders artist info and local albums', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          child: const ArtistDetailScreen(artistId: 'artist-1'),
          database: database,
          overrides: [
            artistByIdProvider('artist-1').overrideWithValue(
              const AsyncData(
                ArtistsTableData(
                  id: 'artist-1',
                  name: 'Artist 1',
                  albumCount: 1,
                ),
              ),
            ),
            albumsByArtistProvider('artist-1').overrideWithValue(
              const AsyncData(<AlbumsTableData>[
                AlbumsTableData(
                  id: 'album-1',
                  name: 'Album 1',
                  artistId: 'artist-1',
                  songsHydrated: true,
                ),
              ]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Artist'), findsOneWidget);
      expect(find.text('Artist 1'), findsOneWidget);
      expect(find.text('1 albums'), findsOneWidget);
      expect(find.text('Album 1'), findsOneWidget);
      await _disposeApp(tester);
    });

    testWidgets('album detail renders album info and local track list', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          child: const AlbumDetailScreen(albumId: 'album-1'),
          database: database,
          overrides: [
            albumProvider('album-1').overrideWithValue(
              const AsyncData(
                AlbumWithSongs(
                  album: AlbumsTableData(
                    id: 'album-1',
                    name: 'Album 1',
                    artistName: 'Artist 1',
                    year: 2025,
                    songsHydrated: true,
                  ),
                  songs: <SongsTableData>[
                    SongsTableData(id: 'song-1', title: 'Song 1', track: 1),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Album'), findsOneWidget);
      expect(find.text('Album 1'), findsOneWidget);
      expect(find.text('Song 1'), findsOneWidget);
      expect(find.textContaining('Artist 1'), findsOneWidget);
      await _disposeApp(tester);
    });

    testWidgets('album play-now ignores rapid repeated taps while in flight', (
      tester,
    ) async {
      final gate = Completer<void>();
      final handler = _DelayedReplaceHandler(gate: gate);

      await tester.pumpWidget(
        _buildApp(
          child: const AlbumDetailScreen(albumId: 'album-rapid'),
          database: database,
          overrides: [
            audioHandlerProvider.overrideWithValue(handler),
            albumProvider('album-rapid').overrideWithValue(
              const AsyncData(
                AlbumWithSongs(
                  album: AlbumsTableData(
                    id: 'album-rapid',
                    name: 'Rapid Album',
                    artistName: 'Artist Rapid',
                    year: 2025,
                    songsHydrated: true,
                  ),
                  songs: <SongsTableData>[
                    SongsTableData(
                      id: 'song-rapid-1',
                      title: 'Rapid Song',
                      track: 1,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final songTile = find.text('Rapid Song');
      expect(songTile, findsOneWidget);

      await tester.tap(songTile);
      await tester.pump();
      await tester.tap(songTile);
      await tester.pump();

      expect(handler.replaceCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
      await _disposeApp(tester);
    });
  });
}
