import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/expandable_player_sheet.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/features/search/presentation/search_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
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
  Future<void> focusDesktopQueueButton(WidgetTester tester) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
      if (label.contains('desktopQueueToggle')) {
        return;
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    fail('Failed to focus desktop queue toggle via Tab traversal.');
  }

  testWidgets('phone layout uses bottom navigation', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(599, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('medium tablet layout keeps bottom navigation', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('expanded tablet layout uses side navigation at 840+ width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(840, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets(
    'desktop-wide shell uses unified desktop sidebar and player bar',
    (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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

      expect(
        find.byKey(const ValueKey('desktopSidebarRegion')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('desktopPlayerBar')), findsOneWidget);
      expect(find.byKey(const ValueKey('railMiniPlayer')), findsNothing);
      expect(find.byType(ExpandablePlayerSheet), findsNothing);
      expect(find.byIcon(Icons.open_in_full), findsNothing);
      expect(container.read(playerSheetExpandedProvider), isFalse);

      await tester.tap(find.byKey(const ValueKey('desktopQueueButton')));
      await tester.pumpAndSettle();

      expect(container.read(queueOverlayVisibleProvider), isTrue);
      expect(container.read(playerSheetExpandedProvider), isFalse);

      await tester.tapAt(const Offset(360, 40));
      await tester.pumpAndSettle();

      expect(container.read(queueOverlayVisibleProvider), isFalse);

      // Clicking the desktop player bar no longer opens the expanded player;
      // the whole-bar InkWell was removed. Verify the bar itself is still present.
      expect(find.byKey(const ValueKey('desktopPlayerBar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact desktop rail keeps rail mini player and avoids desktop bar',
    (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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

      expect(find.byKey(const ValueKey('railMiniPlayer')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktopPlayerBar')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone landscape falls back to bottom nav when height is tight', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 420);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets(
    'phone landscape rail uses compact nav without library sub-buttons',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 560);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(),
          showLikedPageProvider.overrideWithValue(true),
          showArtistsPageProvider.overrideWithValue(true),
          showPlaylistsPageProvider.overrideWithValue(true),
          showRadioPageProvider.overrideWithValue(true),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const NavisApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.byKey(const ValueKey('railNavTile-1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('railLibrarySection-liked')),
        findsNothing,
      );
      expect(find.text('Library - Albums'), findsNothing);
      expect(find.byType(TabBar), findsOneWidget);
    },
  );

  testWidgets('expanded player uses bottom-sheet mode on phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(599, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    expect(container.read(playerSheetExpandedProvider), isTrue);
    expect(find.byType(ExpandablePlayerSheet), findsOneWidget);
  });

  testWidgets('expanded player uses embedded now-playing mode on rail', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    expect(container.read(playerSheetExpandedProvider), isTrue);
    expect(find.byType(NowPlayingScreen), findsOneWidget);
    expect(find.byType(ExpandablePlayerSheet), findsNothing);
  });

  testWidgets('expanded player keeps sheet mode on medium tablet', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    expect(container.read(playerSheetExpandedProvider), isTrue);
    expect(find.byType(ExpandablePlayerSheet), findsOneWidget);
  });

  testWidgets(
    'keeps deep settings route stable while resizing across layouts',
    (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(599, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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

      const transitions = <Size>[
        Size(700, 1000),
        Size(1024, 1000),
        Size(1280, 1000),
        Size(1700, 1000),
        Size(599, 1000),
      ];

      for (final size in transitions) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();

        expect(find.text('Cache & Storage'), findsWidgets);
      }
    },
  );

  testWidgets('preserves active search branch through display transitions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(599, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    await tester.tap(find.byIcon(Icons.search).first);
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);

    tester.view.physicalSize = const Size(700, 1000);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(SearchScreen), findsOneWidget);

    tester.view.physicalSize = const Size(1024, 1000);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(SearchScreen), findsOneWidget);

    tester.view.physicalSize = const Size(1280, 1000);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(SearchScreen), findsOneWidget);

    tester.view.physicalSize = const Size(599, 1000);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(SearchScreen), findsOneWidget);
  });

  testWidgets('desktop shortcuts stay active on compact desktop widths', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    expect(container.read(queueOverlayVisibleProvider), isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(container.read(queueOverlayVisibleProvider), isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(container.read(queueOverlayVisibleProvider), isFalse);
  });

  testWidgets(
    'wide rail library button and subsections navigate consistently',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(),
          showLikedPageProvider.overrideWithValue(true),
          showArtistsPageProvider.overrideWithValue(true),
          showPlaylistsPageProvider.overrideWithValue(true),
          showRadioPageProvider.overrideWithValue(true),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const NavisApp(),
        ),
      );
      await tester.pumpAndSettle();

      final libraryMain = find.byKey(const ValueKey('railNavTile-1'));
      expect(libraryMain, findsOneWidget);

      await tester.tap(libraryMain);
      await tester.pumpAndSettle();

      expect(find.text('Library - Albums'), findsOneWidget);
      expect(container.read(librarySectionProvider), LibrarySection.albums);

      await tester.tap(find.byKey(const ValueKey('railLibrarySection-liked')));
      await tester.pumpAndSettle();

      expect(find.text('Library - Liked'), findsOneWidget);
      expect(container.read(librarySectionProvider), LibrarySection.liked);

      await tester.tap(libraryMain);
      await tester.pumpAndSettle();

      expect(find.text('Library - Albums'), findsOneWidget);
      expect(container.read(librarySectionProvider), LibrarySection.albums);
    },
  );

  testWidgets(
    'desktop-wide sidebar keeps library subsection navigation visible',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(),
          showLikedPageProvider.overrideWithValue(true),
          showArtistsPageProvider.overrideWithValue(true),
          showPlaylistsPageProvider.overrideWithValue(true),
          showRadioPageProvider.overrideWithValue(true),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const NavisApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('railNavTile-1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('railLibrarySection-liked')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tight vertical rail falls back to tabbed library navigation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 640);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(),
          showLikedPageProvider.overrideWithValue(true),
          showArtistsPageProvider.overrideWithValue(true),
          showPlaylistsPageProvider.overrideWithValue(true),
          showRadioPageProvider.overrideWithValue(true),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const NavisApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('railNavTile-1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('railLibrarySection-liked')),
        findsNothing,
      );
      expect(find.text('Library - Albums'), findsNothing);
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('Albums'), findsWidgets);
    },
  );

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

  testWidgets(
    'escape closes queue before collapsing now playing',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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
      expect(container.read(playerSheetExpandedProvider), isTrue);

      container.read(playerOverlayStackProvider.notifier).showQueue();
      await tester.pumpAndSettle();
      expect(container.read(queueOverlayVisibleProvider), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(container.read(queueOverlayVisibleProvider), isFalse);
      expect(container.read(playerSheetExpandedProvider), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(container.read(playerSheetExpandedProvider), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'escape does not open now playing when nothing dismissible is open',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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

      expect(container.read(playerSheetExpandedProvider), isFalse);
      expect(container.read(queueOverlayVisibleProvider), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(container.read(playerSheetExpandedProvider), isFalse);
      expect(container.read(queueOverlayVisibleProvider), isFalse);
    },
  );

  testWidgets(
    'escape closes collapsed queue and does not reopen now playing',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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

      expect(container.read(playerSheetExpandedProvider), isFalse);
      container.read(playerOverlayStackProvider.notifier).showQueueOnly();
      await tester.pumpAndSettle();
      expect(container.read(queueOverlayVisibleProvider), isTrue);
      expect(container.read(playerSheetExpandedProvider), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(container.read(queueOverlayVisibleProvider), isFalse);
      expect(container.read(playerSheetExpandedProvider), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(container.read(playerSheetExpandedProvider), isFalse);
    },
  );

  testWidgets('desktop quick-search opens via Ctrl+F and submits query', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final quickSearchField = find.byKey(
      const ValueKey('desktopQuickSearchField'),
    );
    expect(quickSearchField, findsOneWidget);

    await tester.enterText(quickSearchField, 'dream theater');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(container.read(searchQueryProvider), 'dream theater');
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(quickSearchField, findsNothing);
  });

  testWidgets('queue dismissal restores focus to desktop queue toggle button', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    final queueButton = find.byKey(const ValueKey('desktopQueueButton'));
    expect(queueButton, findsOneWidget);

    await tester.tap(queueButton);
    await tester.pumpAndSettle();
    expect(container.read(queueOverlayVisibleProvider), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(container.read(queueOverlayVisibleProvider), isFalse);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      contains('desktopQueueToggle'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'space stays playback-only while enter activates focused desktop controls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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

      await focusDesktopQueueButton(tester);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        contains('desktopQueueToggle'),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(container.read(queueOverlayVisibleProvider), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(container.read(queueOverlayVisibleProvider), isTrue);
    },
  );

  testWidgets('mouse click clears tab-selected desktop focus', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    await focusDesktopQueueButton(tester);

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      contains('desktopQueueToggle'),
    );

    await tester.tapAt(const Offset(420, 160));
    await tester.pumpAndSettle();

    final focusLabel = FocusManager.instance.primaryFocus?.debugLabel;
    expect(
      focusLabel == null || !focusLabel.contains('desktopQueueToggle'),
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(container.read(queueOverlayVisibleProvider), isFalse);
  });

  testWidgets(
    'desktop player and desktop now playing expose focus mode toggles',
    (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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

      expect(
        find.byKey(const ValueKey('desktopPlayerFocusButton')),
        findsOneWidget,
      );

      container.read(playerOverlayStackProvider.notifier).expand();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('desktopNowPlayingFocusButton')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'adaptive input interactions remain stable across tablet and desktop widths',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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

      const widths = <double>[700, 840, 1200, 1366];
      for (final width in widths) {
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpAndSettle();

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();

        if (width >= 1200) {
          container.read(playerOverlayStackProvider.notifier).expand();
          await tester.pumpAndSettle();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(container.read(queueOverlayVisibleProvider), isFalse);
          expect(container.read(playerSheetExpandedProvider), isFalse);
        }

        expect(tester.takeException(), isNull);
      }
    },
  );
}
