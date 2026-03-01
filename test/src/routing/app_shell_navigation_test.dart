import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/app_shell.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../helpers/test_database.dart';

class _StaticReachabilityController extends ServerReachabilityController {
  _StaticReachabilityController(this._state);

  final ServerReachabilityState _state;

  @override
  ServerReachabilityState build() => _state;
}

class _StaticLibrarySyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return const LibrarySyncState.idle();
  }

  @override
  Future<LibrarySyncState> syncNow({
    bool forceFull = false,
    bool preferIncremental = false,
  }) async {
    return const LibrarySyncState.idle();
  }
}

class _NoopScrobbleDispatchController extends ScrobbleDispatchController {
  @override
  int build() => 0;
}

ProviderContainer _createContainerWithDatabase({
  List<Override> overrides = const <Override>[],
}) {
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(database, overrides: overrides),
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  return container;
}

List<Override> _authenticatedShellOverrides({
  PlaybackSnapshot playback = _activePlayback,
}) {
  return <Override>[
    serverConfigStateProvider.overrideWithValue(
      const AsyncData(
        ServerConfigModel(
          url: 'https://example.com',
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
      ),
    ),
    serverReachabilityControllerProvider.overrideWith(
      () => _StaticReachabilityController(
        const ServerReachabilityState(
          status: ServerReachabilityStatus.online,
        ),
      ),
    ),
    librarySyncControllerProvider.overrideWith(
      _StaticLibrarySyncController.new,
    ),
    homeRecentlyPlayedProvider.overrideWithValue(
      const AsyncData(<SongsTableData>[]),
    ),
    homeRecentlyAddedProvider.overrideWithValue(const AsyncData(<Album>[])),
    homeFrequentAlbumsProvider.overrideWithValue(const AsyncData(<Album>[])),
    homeRandomAlbumsProvider.overrideWithValue(const AsyncData(<Album>[])),
    homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
    artistInfoProvider.overrideWith((ref, artistId) async => null),
    scrobbleDispatchControllerProvider.overrideWith(
      _NoopScrobbleDispatchController.new,
    ),
    playbackSnapshotProvider.overrideWith((ref) => Stream.value(playback)),
  ];
}

const PlaybackSnapshot _activePlayback = PlaybackSnapshot(
  queueSongIds: <String>['song-1', 'song-2'],
  currentSongId: 'song-1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration(seconds: 42),
  duration: Duration(minutes: 3, seconds: 30),
  bufferedPosition: Duration(minutes: 1),
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

void main() {
  testWidgets('expanded player takes back priority over branch detail routes', (
    tester,
  ) async {
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
    );
    await tester.pumpAndSettle();

    final router = container.read(appRouterProvider);
    router.go('/settings/cache');
    await tester.pumpAndSettle();

    expect(find.text('Cache & Storage'), findsWidgets);

    container.read(playerOverlayStackProvider.notifier).expand();
    await tester.pumpAndSettle();

    expect(container.read(playerSheetExpandedProvider), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(container.read(playerSheetExpandedProvider), isFalse);
    expect(find.text('Cache & Storage'), findsWidgets);
  });

  testWidgets('system back dismisses queue before collapsing now playing', (
    tester,
  ) async {
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
    );
    await tester.pumpAndSettle();

    container.read(playerOverlayStackProvider.notifier).showQueue();
    await tester.pumpAndSettle();

    expect(find.text('Queue'), findsOneWidget);
    expect(container.read(playerSheetExpandedProvider), isTrue);
    expect(container.read(queueOverlayVisibleProvider), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Queue'), findsNothing);
    expect(container.read(playerSheetExpandedProvider), isTrue);
    expect(container.read(queueOverlayVisibleProvider), isFalse);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(container.read(playerSheetExpandedProvider), isFalse);
  });

  testWidgets('root modal back does not mutate shell overlay state', (
    tester,
  ) async {
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
    );
    await tester.pumpAndSettle();

    container.read(playerOverlayStackProvider.notifier).expand();
    await tester.pumpAndSettle();

    final shellContext = tester.element(find.byType(AppShell));
    unawaited(
      showDialog<void>(
        context: shellContext,
        builder: (context) => const AlertDialog(
          title: Text('Test dialog'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Test dialog'), findsOneWidget);
    expect(container.read(playerSheetExpandedProvider), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Test dialog'), findsNothing);
    expect(container.read(playerSheetExpandedProvider), isTrue);
  });
}
