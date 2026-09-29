import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/artist_context_menu.dart';
import 'package:navis/src/common_widgets/artist_playback_action.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/artist_playback_controller.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../helpers/test_theme.dart';

class _QueueSpy extends QueueController {
  int calls = 0;
  int appends = 0;
  @override
  Future<void> addTableData(List<SongsTableData> songs) async {
    appends++;
    state = [...state, ...songs.map((song) => song.id)];
  }

  @override
  List<String> build() => ['previous'];
  @override
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
  }) async {
    calls++;
    state = songs.map((song) => song.id).toList();
  }
}

void main() {
  const song = SongsTableData(
    id: 'song',
    title: 'Track',
    isProvisional: false,
    isExternal: false,
  );
  const failed = LibrarySyncState(
    status: LibrarySyncStatus.failed,
    stage: LibrarySyncStage.completed,
  );
  const succeeded = LibrarySyncState(
    status: LibrarySyncStatus.succeeded,
    stage: LibrarySyncStage.completed,
  );

  Future<_QueueSpy> mount(
    WidgetTester tester, {
    required Future<LibrarySyncState> Function() hydrate,
    List<SongsTableData> songs = const [song],
    bool menu = false,
    bool desktop = false,
    bool add = false,
  }) async {
    final queue = _QueueSpy();
    final container = ProviderContainer(
      overrides: [
        subsonicApiProvider.overrideWithValue(null),
        playerStateProvider.overrideWithValue(const PlaybackSnapshot.idle()),
        artistByIdProvider.overrideWith((ref, id) => Stream.value(null)),
        queueProvider.overrideWith(() => queue),
        artistPlaybackResolverProvider.overrideWithValue(
          ArtistPlaybackResolver(
            readSnapshot: (_) async => ArtistPlaybackSnapshot(
              artist: null,
              albums: const [],
              songs: songs,
            ),
            hydrate: (_) => hydrate(),
            canHydrate: () => true,
            isOffline: () => false,
            isLocallyPlayable: (_) async => true,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Column(
                children: [
                  FilledButton(
                    onPressed: () => menu
                        ? showArtistContextMenu(
                            context,
                            ref,
                            'artist',
                            anchor: desktop ? const Offset(100, 100) : null,
                          )
                        : startArtistPlayback(
                            container,
                            'artist',
                            ArtistPlaybackAction.play,
                          ),
                    child: const Text('Artist action'),
                  ),
                  const ArtistPlaybackProgressIndicator(artistId: 'artist'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Artist action'));
    await tester.pump();
    if (menu) {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(add ? 'Add to Queue' : 'Play'));
      await tester.pump();
    }
    return queue;
  }

  for (final width in [390.0, 800.0, 1200.0]) {
    testWidgets('compact progress and cancel fit a $width window', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gate = Completer<LibrarySyncState>();
      final queue = await mount(tester, hydrate: () => gate.future);
      await tester.pump();
      expect(queue.calls, 1);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const ValueKey('artist-playback-cancel')));
      await tester.pump();
      expect(find.byType(ArtistPlaybackProgressIndicator), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      gate.complete(succeeded);
      await tester.pumpAndSettle();
      expect(queue.calls, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'play starts without a modal while background loading continues',
    (
      tester,
    ) async {
      final gate = Completer<LibrarySyncState>();
      final queue = await mount(tester, hydrate: () => gate.future);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Artist action'), findsOneWidget);
      expect(find.text('Loading artist queue'), findsOneWidget);
      expect(queue.calls, 1);
      // Navigation and ordinary buttons remain available during hydration.
      await tester.tap(find.text('Artist action'));
      await tester.pump();
      expect(queue.calls, 1);
      gate.complete(succeeded);
      await tester.pumpAndSettle();
      expect(queue.calls, 1);
    },
  );

  testWidgets('partial metadata automatically queues identified tracks', (
    tester,
  ) async {
    final queue = await mount(tester, hydrate: () async => failed);
    await tester.pumpAndSettle();
    expect(queue.calls, 1);
    expect(find.byKey(const ValueKey('artist-playback-dialog')), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Play available'), findsNothing);
  });

  testWidgets('empty selection closes without changing the queue', (
    tester,
  ) async {
    final queue = await mount(tester, hydrate: () async => failed, songs: []);
    await tester.pumpAndSettle();
    expect(queue.calls, 0);
    expect(find.byKey(const ValueKey('artist-playback-dialog')), findsNothing);
  });

  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? 'desktop' : 'touch'} menu action survives menu disposal',
      (tester) async {
        final gate = Completer<LibrarySyncState>();
        final queue = await mount(
          tester,
          hydrate: () => gate.future,
          menu: true,
          desktop: desktop,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(queue.calls, 1);
        gate.complete(succeeded);
        await tester.pumpAndSettle();
        expect(queue.calls, 1);
      },
    );
    testWidgets(
      '${desktop ? 'desktop' : 'touch'} artist Add to Queue appends one batch',
      (tester) async {
        final queue = await mount(
          tester,
          hydrate: () async => succeeded,
          menu: true,
          desktop: desktop,
          add: true,
        );
        await tester.pumpAndSettle();
        expect(queue.appends, 1);
        expect(queue.calls, 0);
      },
    );
  }
}
