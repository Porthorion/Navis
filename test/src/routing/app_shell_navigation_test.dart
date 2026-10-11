import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show SemanticsAction;

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/expandable_player_sheet.dart';
import 'package:navis/src/common_widgets/navis_tooltip.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/presentation/integrations_notice_card.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/common_widgets/cover_art_source.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_scope.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/player/presentation/now_playing_backdrop.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/features/search/presentation/search_screen.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../helpers/library_copy_api.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_theme.dart';

import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/features/settings/presentation/settings_screen.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

import '../../helpers/reachability_fakes.dart';

class _StaticLibrarySyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return const LibrarySyncState.idle();
  }

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) async {
    return const LibrarySyncState.idle();
  }
}

class _NoopScrobbleDispatchController extends ScrobbleDispatchController {
  @override
  int build() => 0;
}

class _RecordingLikePlaybackHandler implements NavisPlaybackHandler {
  int toggleLikeCalls = 0;
  Duration? sought;
  int seekCalls = 0;
  PlaybackSnapshot playback = _activePlayback;

  @override
  Future<void> seek(Duration position) async {
    sought = position;
    seekCalls++;
  }

  @override
  Future<void> toggleLike() async {
    toggleLikeCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) {
      return switch (invocation.memberName) {
        #equalizerCapabilities => EqCapabilities.unavailable,
        #snapshot => playback,
        #snapshotStream => const Stream<PlaybackSnapshot>.empty(),
        #transportVisualCueStream => const Stream<TransportVisualCue>.empty(),
        #positionStream => const Stream<Duration>.empty(),
        #bufferState => const PlaybackBufferState.idle(),
        #bufferStateStream => const Stream<PlaybackBufferState>.empty(),
        #currentMediaItem => null,
        #mediaItemStream => const Stream<MediaItem?>.empty(),
        #loadFailureStream => const Stream<PlaybackLoadFailure>.empty(),
        #droppedSongsStream => const Stream<QueueSongsDropped>.empty(),
        #radioStreamErrorStream => const Stream<void>.empty(),
        _ => null,
      };
    }
    return Future<void>.value();
  }
}

class _StaticDesktopShortcutBindingsNotifier
    extends DesktopShortcutBindingsNotifier {
  @override
  Map<DesktopCommandAction, DesktopShortcutBinding?> build() {
    return defaultDesktopShortcutBindings();
  }
}

class _MutablePlaybackController extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => _activePlayback;

  PlaybackSnapshot get snapshot => state;

  set snapshot(PlaybackSnapshot value) => state = value;
}

final _mutablePlaybackProvider =
    NotifierProvider<_MutablePlaybackController, PlaybackSnapshot>(
      _MutablePlaybackController.new,
    );

ProviderContainer _createContainerWithDatabase({
  List<Override> overrides = const <Override>[],
}) {
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        onboardingVersionProvider.overrideWithValue(
          const AsyncData(currentOnboardingVersion),
        ),
        ...overrides,
      ],
    ),
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  return container;
}

List<Override> _authenticatedShellOverrides({
  PlaybackSnapshot playback = _activePlayback,
  ValueNotifier<PlaybackSnapshot>? playing,
  ServerReachabilityStatus reachability = ServerReachabilityStatus.online,
  bool desktopRuntime = false,
}) {
  return <Override>[
    changelogToShowProvider.overrideWith((ref) async => null),
    // Like the release notes row, the 1.5.0 notice is not part of the shell.
    integrationsNoticeVisibleProvider.overrideWithValue(false),
    initialSyncRequiredProvider.overrideWithValue(const AsyncData(false)),
    desktopPresentationRuntimeProvider.overrideWithValue(desktopRuntime),
    networkTypeProvider.overrideWithValue(NetworkType.wifi),
    desktopShortcutBindingsProvider.overrideWith(
      _StaticDesktopShortcutBindingsNotifier.new,
    ),
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
      () => StaticReachabilityController(
        ServerReachabilityState(status: reachability),
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
    listenBrainzDiscoverStreamProvider.overrideWithValue(
      const AsyncData(<ListenBrainzDiscoverPlaylist>[]),
    ),
    artistInfoProvider.overrideWith((ref, artistId) async => null),
    scrobbleDispatchControllerProvider.overrideWith(
      _NoopScrobbleDispatchController.new,
    ),
    playbackSnapshotProvider.overrideWith((ref) {
      if (playing == null) return Stream.value(playback);
      void changed() => ref.invalidateSelf();
      playing.addListener(changed);
      ref.onDispose(() => playing.removeListener(changed));
      return Stream.value(playing.value);
    }),
    lyricsProvider.overrideWith(
      (ref, songId) async => const LyricsResolution(
        lyrics: LyricsList(),
        source: LyricsSource.serverPlain,
      ),
    ),
    packageInfoProvider.overrideWithValue(
      AsyncData<PackageInfo>(
        PackageInfo(
          appName: 'Navis',
          packageName: 'org.navis.app',
          version: '1.2.3',
          buildNumber: '42',
          buildSignature: '',
        ),
      ),
    ),
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

const SongsTableData _longMetadataSong = SongsTableData(
  id: 'song-1',
  title: 'A Long Track Title That Must Stay Legible Without Taking Over the Desktop Player',
  artistName: 'An Artist With A Deliberately Long Name For Metadata Coverage',
  albumName:
      'A Representative Album With Enough Metadata To Exercise The Layout',
  artistId: 'artist-1',
  albumId: 'album-1',
  isProvisional: false,
  isExternal: false,
);

const SongsTableData _remoteMetadataSong = SongsTableData(
  id: 'song-1',
  title: 'A Remote Track With Clear Provenance',
  artistName: 'Remote Artist',
  albumName: 'Remote Album',
  artistId: 'artist-1',
  albumId: 'album-1',
  isProvisional: false,
  isExternal: true,
);

void main() {
  testWidgets(
    'desktop times preview a drag and release through the existing handler',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      final handler = _RecordingLikePlaybackHandler();
      final container = _createContainerWithDatabase(
        overrides: [
          ..._authenticatedShellOverrides(desktopRuntime: true),
          audioHandlerProvider.overrideWithValue(handler),
          playbackPositionProvider.overrideWith(
            (ref) => Stream.value(const Duration(seconds: 42)),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();
      expect(find.text('0:42'), findsWidgets);
      expect(find.text('3:30'), findsWidgets);
      final finder = find.byKey(const ValueKey('desktopPlayerSeekSlider'));
      final slider = tester.widget<Slider>(finder);
      slider.onChangeStart!(90000);
      slider.onChanged!(90000);
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('desktopPlayerElapsed')))
            .data,
        '1:30',
      );
      expect(handler.sought, isNull);
      tester.widget<Slider>(finder).onChangeEnd!(90000);
      await tester.pump();
      expect(handler.sought, const Duration(seconds: 90));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the shell starts the download service at launch', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(desktopRuntime: true),
    );
    // Created, and so started, before any download control is used: an
    // interrupted download resumes after a restart.
    expect(container.exists(downloadServiceProvider), isFalse);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();
    expect(container.exists(downloadServiceProvider), isTrue);
  });

  testWidgets('desktop player tooltip cycles keep semantics consistent', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(desktopRuntime: true),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 250));
    for (final key in <String>[
      'desktopPlayerFavoriteButton',
      'desktopPlayerLyricsButton',
      'desktopQueueButton',
      'desktopPlayerMiniPlayerButton',
    ]) {
      final target = find.byKey(ValueKey<String>(key));
      expect(target, findsOneWidget);
      final semanticNode = tester.getSemantics(target);
      final semanticId = semanticNode.id;
      final label = semanticNode.label;
      for (var cycle = 0; cycle < 3; cycle++) {
        await mouse.moveTo(tester.getCenter(target));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(NavisTooltip.defaultBubbleKey), findsOneWidget);
        expect(tester.getSemantics(target).id, semanticId);
        expect(tester.getSemantics(target).label, label);
        await mouse.moveTo(const Offset(400, 250));
        await tester.pumpAndSettle();
        expect(find.byKey(NavisTooltip.defaultBubbleKey), findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
    await mouse.removePointer();
    semantics.dispose();
  });
  IconButton desktopActionButton(WidgetTester tester, String key) {
    return tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(ValueKey<String>(key)),
        matching: find.byType(IconButton),
      ),
    );
  }

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

  Future<void> pumpDesktopLongMetadata(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        songByIdProvider.overrideWith(
          (ref, songId) => Stream.value(
            songId == _longMetadataSong.id ? _longMetadataSong : null,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();
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
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).labelBehavior,
      NavigationDestinationLabelBehavior.onlyShowSelected,
    );
  });

  testWidgets('offline status uses a neutral retrying surface on desktop', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(
        reachability: ServerReachabilityStatus.offline,
        desktopRuntime: true,
      ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    final offlineMessage = find.text('Server unreachable. Retrying every 30s.');
    expect(offlineMessage, findsOneWidget);
    final banner = find
        .ancestor(of: offlineMessage, matching: find.byType(Material))
        .first;
    expect(
      tester.widget<Material>(banner).color,
      Theme.of(tester.element(banner)).colorScheme.surfaceContainerHigh,
    );
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
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets(
    'desktop-wide shell uses unified desktop sidebar and player bar',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = _createContainerWithDatabase(
        overrides: _authenticatedShellOverrides(desktopRuntime: true),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
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

  for (final style in <String>['neutral', 'pastel', 'immersive', 'night']) {
    testWidgets('OLED $style desktop sidebar and player bar are pure black', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final settings = const AppSettingsModel.defaults().copyWith(
        themeMode: 'oled',
        colorStyle: style,
      );
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(desktopRuntime: true),
          appSettingsProvider.overrideWithValue(AsyncData(settings)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      final sidebar = find
          .ancestor(
            of: find.byKey(const ValueKey<String>('desktopSidebarRegion')),
            matching: find.byType(Material),
          )
          .first;
      expect(tester.widget<Material>(sidebar).color, Colors.black);
      expect(
        tester
            .widget<Material>(
              find.byKey(const ValueKey<String>('desktopPlayerBar')),
            )
            .color,
        Colors.black,
      );
    });
  }

  testWidgets('desktop sidebar autohide retains an icon-only navigation rail', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final settings = const AppSettingsModel.defaults().copyWith(
      desktopNavbarAutohide: true,
    );
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        appSettingsProvider.overrideWithValue(AsyncData(settings)),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    final sidebar = find.byKey(const ValueKey<String>('desktopSidebarRegion'));
    expect(sidebar, findsOneWidget);
    expect(tester.getSize(sidebar).width, 64);
    expect(
      find.descendant(of: sidebar, matching: find.text('Home')),
      findsNothing,
    );
    expect(
      find.descendant(of: sidebar, matching: find.byIcon(Icons.home_rounded)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact Desktop View keeps the persistent desktop player bar', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(desktopRuntime: true),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('railMiniPlayer')), findsNothing);
    expect(find.byKey(const ValueKey('desktopPlayerBar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('800x600 Desktop View keeps an operable empty player bar', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(
        desktopRuntime: true,
        playback: const PlaybackSnapshot.idle(),
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktopPlayerBar')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('desktopPlayerVolumeSlider')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('desktopPlayerMiniPlayerButton')),
      findsOneWidget,
    );
    for (final key in <String>[
      'desktopPlayerFavoriteButton',
      'desktopPlayerLyricsButton',
      'desktopQueueButton',
    ]) {
      final finder = find.byKey(ValueKey<String>(key));
      expect(finder, findsOneWidget);
      expect(desktopActionButton(tester, key).onPressed, isNull);
      expect(tester.getSize(finder), const Size(44, 44));
      final semantics = tester.getSemantics(finder);
      expect(semantics.label, 'Unavailable Until Something Is Playing');
      expect(
        semantics.getSemanticsData().hasAction(SemanticsAction.tap),
        isFalse,
      );
    }
    expect(find.text('Nothing playing'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const ValueKey('railMiniPlayer')), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey<String>('appShellScaffold')),
      matchesGoldenFile('goldens/desktop_view_empty_800x600.png'),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

  testWidgets(
    'Mini Player keeps the navigation shell and ignores page shortcuts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final windowController = DesktopWindowController.fallback(
        desktopRuntime: true,
      );
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(
            desktopRuntime: true,
            playback: const PlaybackSnapshot.idle(),
          ),
          desktopWindowControllerProvider.overrideWith(
            (ref) => windowController,
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();
      final router = container.read(appRouterProvider);
      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();
      unawaited(router.push<void>(SettingsPage.cache.location));
      await tester.pumpAndSettle();
      final shellState = tester.state(find.byType(StatefulNavigationShell));

      // The window shrinks with the mode, as the real window controller does.
      await windowController.setMiniPlayerMode(true);
      tester.view.physicalSize = const Size(720, 405);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktopMiniPlayerSurface')),
        findsOneWidget,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, SettingsPage.cache.location);

      await windowController.setMiniPlayerMode(false);
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(StatefulNavigationShell)),
        same(shellState),
      );
      expect(router.state.uri.path, SettingsPage.cache.location);
      expect(router.canPop(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('720x405 Mini Player uses the dedicated desktop surface', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(720, 405);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final windowController = DesktopWindowController.fallback(
      desktopRuntime: true,
    );
    await windowController.setMiniPlayerMode(true);
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(
          desktopRuntime: true,
          playback: const PlaybackSnapshot.idle(),
        ),
        desktopWindowControllerProvider.overrideWith((ref) => windowController),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('desktopMiniPlayerSurface')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('miniPlayerExitButton')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniPlayerAlwaysOnTop')), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const ValueKey('railMiniPlayer')), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey('desktopMiniPlayerSurface')),
      matchesGoldenFile('goldens/mini_player_empty_720x405.png'),
    );
  });

  testWidgets('compact Mini Player previews dragging and commits once', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(560, 360);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final windowController = DesktopWindowController.fallback(
      desktopRuntime: true,
    );
    await windowController.setMiniPlayerMode(true);
    final handler = _RecordingLikePlaybackHandler()
      ..playback = _activePlayback.copyWith(
        pendingSeekPosition: const Duration(seconds: 90),
      );
    final container = _createContainerWithDatabase(
      overrides: [
        ..._authenticatedShellOverrides(
          desktopRuntime: true,
          playback: handler.playback,
        ),
        desktopWindowControllerProvider.overrideWith((ref) => windowController),
        audioHandlerProvider.overrideWith((ref) => handler),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('desktopMiniPlayerSeekSlider'));
    expect(slider, findsOneWidget);
    expect(tester.widget<Slider>(slider).value, 90000);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    final intermediateCalls = handler.seekCalls;
    await gesture.up();
    await tester.pump();
    expect(
      intermediateCalls,
      0,
      reason: 'Dragging should only preview the target, without repeatedly seeking the native player.',
    );
    expect(handler.seekCalls, 1);
  });

  testWidgets(
    '720x405 Mini Player opens the richer playback composition first',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(720, 405);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final windowController = DesktopWindowController.fallback(
        desktopRuntime: true,
      );
      await windowController.setMiniPlayerMode(true);
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(desktopRuntime: true),
          desktopWindowControllerProvider.overrideWith(
            (ref) => windowController,
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      final volume = find.byKey(
        const ValueKey<String>('desktopMiniPlayerVolumeSlider'),
      );
      final like = find.byTooltip('Like');
      expect(volume, findsOneWidget);
      expect(like, findsOneWidget);
      final volumeRect = tester.getRect(volume);
      expect(volumeRect.width, greaterThan(220));
      expect(volumeRect.left, greaterThan(300));
      expect(volumeRect.top, greaterThanOrEqualTo(tester.getRect(like).bottom));
      expect(
        find.byKey(const ValueKey<String>('desktopMiniPlayerTightPlayback')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey('desktopMiniPlayerSurface')),
        matchesGoldenFile('goldens/mini_player_active_720x405.png'),
      );
    },
  );

  testWidgets(
    'Mini Player animates Queue dismissal before restoring edge controls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(720, 405);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final windowController = DesktopWindowController.fallback(
        desktopRuntime: true,
      );
      await windowController.setMiniPlayerMode(true);
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(desktopRuntime: true),
          desktopWindowControllerProvider.overrideWith(
            (ref) => windowController,
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Queue'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const ValueKey<String>('compact-wide-queue')),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey<String>('miniPlayerFloatingWindowControls')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(
                const ValueKey<String>('miniPlayerFloatingWindowControlsFade'),
              ),
            )
            .opacity,
        0,
      );

      tester.widget<QueueSheet>(find.byType(QueueSheet)).onClose!.call();
      await tester.pump();

      // The close action must leave the sheet mounted while its reverse
      // transition plays, rather than popping it out of the tree immediately.
      expect(
        find.byKey(const ValueKey<String>('compact-wide-queue')),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey<String>('miniPlayerFloatingWindowControls')),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('compact-wide-queue')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('miniPlayerFloatingWindowControls')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('restored Desktop queue enables only resumable Play', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1008, 640);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final restoredQueue = _activePlayback.copyWith(
      currentSongId: '',
      currentIndex: -1,
      playing: false,
      position: Duration.zero,
      duration: Duration.zero,
    );
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(
        desktopRuntime: true,
        playback: restoredQueue,
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    IconButton button(String key) {
      final direct = find.byKey(ValueKey<String>(key));
      if (direct.evaluate().first.widget is IconButton) {
        return tester.widget<IconButton>(direct);
      }
      return desktopActionButton(tester, key);
    }

    expect(button('desktopPlayerPlayPauseButton').onPressed, isNotNull);
    expect(button('desktopPlayerInstantMixButton').onPressed, isNull);
    expect(button('desktopPlayerPreviousButton').onPressed, isNull);
    expect(button('desktopPlayerNextButton').onPressed, isNull);
    expect(button('desktopPlayerRepeatButton').onPressed, isNull);
    expect(button('desktopPlayerFavoriteButton').onPressed, isNull);
    expect(button('desktopPlayerLyricsButton').onPressed, isNull);
    expect(button('desktopQueueButton').onPressed, isNull);
    expect(find.text('Nothing playing'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop Server Mix button accepts a remote song with a library copy',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1008, 640);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(
            desktopRuntime: true,
            playback: _activePlayback.copyWith(currentSongId: 'ext-remote-1'),
          ),
          preferredMixModeProvider.overrideWithValue(
            PreferredMixMode.legacyInstantMix,
          ),
          subsonicApiProvider.overrideWithValue(
            LibraryCopyApiClient(const {'ext-remote-1': 'copy-1'}),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      final direct = find.byKey(
        const ValueKey<String>('desktopPlayerInstantMixButton'),
      );
      final button = direct.evaluate().first.widget is IconButton
          ? tester.widget<IconButton>(direct)
          : desktopActionButton(tester, 'desktopPlayerInstantMixButton');
      expect(button.onPressed, isNotNull);
      expect(
        button.tooltip,
        isNot('Instant Mix requires a locally scanned track.'),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop Server Mix button is disabled for a remote song without a library copy',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1008, 640);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(
            desktopRuntime: true,
            playback: _activePlayback.copyWith(currentSongId: 'ext-remote-1'),
          ),
          preferredMixModeProvider.overrideWithValue(
            PreferredMixMode.legacyInstantMix,
          ),
          subsonicApiProvider.overrideWithValue(LibraryCopyApiClient(const {})),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      final direct = find.byKey(
        const ValueKey<String>('desktopPlayerInstantMixButton'),
      );
      final button = direct.evaluate().first.widget is IconButton
          ? tester.widget<IconButton>(direct)
          : desktopActionButton(tester, 'desktopPlayerInstantMixButton');
      expect(button.onPressed, isNull);
      expect(button.tooltip, 'Instant Mix requires a locally scanned track.');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('800x600 active Desktop View player golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(desktopRuntime: true),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey<String>('appShellScaffold')),
      matchesGoldenFile('goldens/desktop_view_active_800x600.png'),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

  testWidgets('800x600 Desktop View preserves remote-source provenance', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        songByIdProvider.overrideWith(
          (ref, songId) => Stream.value(
            songId == _remoteMetadataSong.id ? _remoteMetadataSong : null,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('remote-source-indicator')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey<String>('appShellScaffold')),
      matchesGoldenFile('goldens/desktop_player_remote_metadata_800x600.png'),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

  testWidgets(
    'desktop player truncates representative long metadata at 800px',
    (tester) async {
      await pumpDesktopLongMetadata(tester, const Size(800, 600));

      for (final text in <String>[
        _longMetadataSong.title,
        _longMetadataSong.artistName!,
      ]) {
        final metadata = tester.widget<Text>(find.text(text));
        expect(metadata.maxLines, 1);
        expect(metadata.overflow, TextOverflow.ellipsis);
      }
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey<String>('appShellScaffold')),
        matchesGoldenFile('goldens/desktop_player_long_metadata_800x600.png'),
      );
      await tester.pump(const Duration(milliseconds: 201));
    },
  );

  testWidgets('desktop player keeps long metadata balanced at standard width', (
    tester,
  ) async {
    await pumpDesktopLongMetadata(tester, const Size(1280, 800));

    expect(find.text(_longMetadataSong.title), findsOneWidget);
    expect(find.text(_longMetadataSong.artistName!), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey<String>('appShellScaffold')),
      matchesGoldenFile('goldens/desktop_player_long_metadata_1280x800.png'),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

  testWidgets('desktop player keeps long metadata balanced at ultra-wide', (
    tester,
  ) async {
    await pumpDesktopLongMetadata(tester, const Size(1920, 1080));

    expect(find.text(_longMetadataSong.title), findsOneWidget);
    expect(find.text(_longMetadataSong.artistName!), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey<String>('appShellScaffold')),
      matchesGoldenFile('goldens/desktop_player_long_metadata_1920x1080.png'),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

  testWidgets('desktop player remains usable at 130 percent text scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        songByIdProvider.overrideWith(
          (ref, songId) => Stream.value(
            songId == _longMetadataSong.id ? _longMetadataSong : null,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData.fromView(tester.view)
            .copyWith(textScaler: const TextScaler.linear(1.3)),
        child: UncontrolledProviderScope(
          container: container,
          child: testNavisApp,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('desktopPlayerBar')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey<String>('desktopPlayerBar')),
      matchesGoldenFile(
        'goldens/desktop_player_long_metadata_800x600_text_scale_130.png',
      ),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

  testWidgets('desktop player remains usable at 200 percent text scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        songByIdProvider.overrideWith(
          (ref, songId) => Stream.value(
            songId == _longMetadataSong.id ? _longMetadataSong : null,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData.fromView(tester.view)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: UncontrolledProviderScope(
          container: container,
          child: testNavisApp,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('desktopPlayerBar')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey<String>('desktopPlayerBar')),
      matchesGoldenFile(
        'goldens/desktop_player_long_metadata_800x600_text_scale_200.png',
      ),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

  testWidgets('887px compact Desktop player action golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(887, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(desktopRuntime: true),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey<String>('appShellScaffold')),
      matchesGoldenFile('goldens/desktop_player_actions_887.png'),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

  for (final size in const <Size>[
    Size(800, 1000),
    Size(887, 900),
    Size(919, 600),
    Size(920, 600),
    Size(930, 1177),
    Size(979, 600),
    Size(980, 600),
    Size(1008, 600),
    Size(1159, 678),
    Size(1306, 853),
    Size(3440, 600),
  ]) {
    testWidgets(
      '${size.width.toInt()}x${size.height.toInt()} Desktop View keeps its persistent player overflow-free',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final container = _createContainerWithDatabase(
          overrides: _authenticatedShellOverrides(desktopRuntime: true),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(container: container, child: testNavisApp),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey<String>('desktopPlayerBar')),
          findsOneWidget,
        );
        for (final key in <String>[
          'desktopPlayerFavoriteButton',
          'desktopPlayerLyricsButton',
          'desktopQueueButton',
          'desktopPlayerMiniPlayerButton',
          'desktopPlayerVolumeSlider',
        ]) {
          expect(
            find.byKey(ValueKey<String>(key)),
            findsOneWidget,
            reason: '$key must remain visible at ${size.width}',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('compact Desktop player actions remain direct and operable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(887, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final playbackHandler = _RecordingLikePlaybackHandler();
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        audioHandlerProvider.overrideWithValue(playbackHandler),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    for (final key in <String>[
      'desktopPlayerFavoriteButton',
      'desktopPlayerLyricsButton',
      'desktopQueueButton',
      'desktopPlayerMiniPlayerButton',
    ]) {
      final finder = find.byKey(ValueKey<String>(key));
      expect(finder, findsOneWidget);
      expect(desktopActionButton(tester, key).onPressed, isNotNull);
      expect(tester.getSize(finder), const Size(44, 44));
      expect(
        tester
            .getSemantics(finder)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('desktopPlayerFavoriteButton')),
    );
    await tester.pump();
    expect(playbackHandler.toggleLikeCalls, 1);

    await tester.tap(
      find.byKey(const ValueKey<String>('desktopPlayerLyricsButton')),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('desktopQueueButton')));
    await tester.pumpAndSettle();
    expect(container.read(queueOverlayVisibleProvider), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop Lyrics retains the current track context in its header',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(desktopRuntime: true),
          songByIdProvider.overrideWith(
            (ref, songId) => Stream.value(
              songId == _longMetadataSong.id ? _longMetadataSong : null,
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('desktopPlayerLyricsButton')),
      );
      await tester.pumpAndSettle();

      final context = find.byKey(
        const ValueKey<String>('desktopLyricsTrackContext'),
      );
      expect(context, findsOneWidget);
      expect(
        tester.getSemantics(context).getSemanticsData().label,
        '${_longMetadataSong.title}, ${_longMetadataSong.artistName}',
      );
      expect(find.byTooltip('Close'), findsOneWidget);
      await expectLater(
        find.byKey(const ValueKey<String>('appShellScaffold')),
        matchesGoldenFile('goldens/desktop_lyrics_header_context_800x600.png'),
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 201));
    },
  );

  testWidgets('desktop Lyrics keeps long context readable at 200 percent', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        songByIdProvider.overrideWith(
          (ref, songId) => Stream.value(
            songId == _longMetadataSong.id ? _longMetadataSong : null,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData.fromView(tester.view)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: UncontrolledProviderScope(
          container: container,
          child: testNavisApp,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('desktopPlayerLyricsButton')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('desktopLyricsTrackContext')),
      findsOneWidget,
    );
    await expectLater(
      find.byKey(const ValueKey<String>('appShellScaffold')),
      matchesGoldenFile(
        'goldens/desktop_lyrics_header_context_800x600_text_scale_200.png',
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 201));
  });

  for (final entry in <(String, String, NavisControlColor)>[
    ('pastel', 'light', NavisControlColor.accent),
    ('pastel', 'dark', NavisControlColor.accent),
    ('neutral', 'light', NavisControlColor.accent),
    ('pastel', 'light', NavisControlColor.white),
    ('neutral', 'dark', NavisControlColor.white),
  ]) {
    testWidgets('phone mini player Play is the solid action in every style '
        '(${entry.$1} ${entry.$2} ${entry.$3.name})', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      const radioPlayback = PlaybackSnapshot(
        queueSongIds: <String>[],
        currentSongId: null,
        currentIndex: null,
        playing: true,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration.zero,
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
        radioStation: RadioStationMetadata(
          stationId: 'radio-1',
          stationName: 'Test Radio',
          streamUrl: 'https://example.com/radio',
        ),
      );
      final settings = const AppSettingsModel.defaults().copyWith(
        themeMode: entry.$2,
        colorStyle: entry.$1,
        controlColor: entry.$3.name,
      );
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(playback: radioPlayback),
          appSettingsProvider.overrideWithValue(AsyncData(settings)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byTooltip('Pause'),
              matching: find.byType(IconButton),
            )
            .first,
      );
      final scheme = Theme.of(tester.element(find.byType(Scaffold).first))
          .colorScheme;
      final data = NavisColorStyleData.of(
        tester.element(find.byType(Scaffold).first),
      );
      expect(
        button.style!.backgroundColor!.resolve(<WidgetState>{}),
        data.playButtonFill(scheme),
      );
      expect(
        button.style!.foregroundColor!.resolve(<WidgetState>{}),
        data.onPlayButtonFill(scheme),
      );
      expect(
        data.playButtonFill(scheme),
        entry.$3 == NavisControlColor.white ? Colors.white : scheme.primary,
      );
      expect(
        button.style!.shape!.resolve(<WidgetState>{}),
        isA<CircleBorder>(),
      );
    });
  }

  for (final controls in NavisControlColor.values) {
    testWidgets('Desktop Play and the selected rail tile follow the accent '
        'contract (${controls.name} controls)', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1008, 640);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final settings = const AppSettingsModel.defaults().copyWith(
        themeMode: 'light',
        colorStyle: 'pastel',
        controlColor: controls.name,
      );
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(
            desktopRuntime: true,
            playback: _activePlayback,
          ),
          appSettingsProvider.overrideWithValue(AsyncData(settings)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold).first);
      final scheme = Theme.of(context).colorScheme;
      final data = NavisColorStyleData.of(context);
      expect(data.controls, controls);

      Color? fillOf(Finder finder) => tester
          .widget<Material>(
            find.descendant(of: finder, matching: find.byType(Material)).first,
          )
          .color;
      final play = find.byKey(
        const ValueKey<String>('desktopPlayerPlayPauseButton'),
      );
      expect(fillOf(play), data.playButtonFill(scheme));
      expect(
        IconTheme.of(
          tester.element(
            find.descendant(of: play, matching: find.byType(Icon)).first,
          ),
        ).color,
        data.onPlayButtonFill(scheme),
      );
      expect(
        fillOf(find.byKey(const ValueKey('railNavTile-0'))),
        data.tonalControlFill(scheme),
      );
      expect(
        controls == NavisControlColor.white,
        data.tonalControlFill(scheme) != scheme.secondaryContainer,
      );
    });
  }

  testWidgets('Desktop radio keeps invalid action slots visibly disabled', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const radioPlayback = PlaybackSnapshot(
      queueSongIds: <String>[],
      currentSongId: null,
      currentIndex: null,
      playing: true,
      processingState: AudioProcessingState.ready,
      position: Duration.zero,
      duration: Duration.zero,
      bufferedPosition: Duration.zero,
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
      radioStation: RadioStationMetadata(
        stationId: 'radio-1',
        stationName: 'Test Radio',
        streamUrl: 'https://example.com/radio',
      ),
    );
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(
        desktopRuntime: true,
        playback: radioPlayback,
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    for (final entry in <(String, String)>[
      ('desktopPlayerFavoriteButton', 'Favorite is unavailable for radio'),
      ('desktopPlayerLyricsButton', 'Lyrics are unavailable for radio'),
      ('desktopQueueButton', 'Queue is unavailable for radio'),
    ]) {
      final key = entry.$1;
      final finder = find.byKey(ValueKey<String>(key));
      expect(finder, findsOneWidget);
      expect(desktopActionButton(tester, key).onPressed, isNull);
      expect(tester.getSize(finder), const Size(44, 44));
      final semantics = tester.getSemantics(finder);
      expect(semantics.label, entry.$2);
      expect(
        semantics.getSemanticsData().hasAction(SemanticsAction.tap),
        isFalse,
      );
    }
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is NavisTooltip &&
            widget.message == 'Favorite is unavailable for radio',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is NavisTooltip &&
            widget.message == 'Lyrics are unavailable for radio',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is NavisTooltip &&
            widget.message == 'Queue is unavailable for radio',
      ),
      findsOneWidget,
    );
    expect(
      desktopActionButton(tester, 'desktopPlayerMiniPlayerButton').onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('560x360 Mini Player keeps its essential empty controls', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(560, 360);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final windowController = DesktopWindowController.fallback(
      desktopRuntime: true,
    );
    await windowController.setMiniPlayerMode(true);
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(
          desktopRuntime: true,
          playback: const PlaybackSnapshot.idle(),
        ),
        desktopWindowControllerProvider.overrideWith((ref) => windowController),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('miniPlayerExitButton')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniPlayerAlwaysOnTop')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey('desktopMiniPlayerSurface')),
      matchesGoldenFile('goldens/mini_player_empty_560x360.png'),
    );
  });

  testWidgets('560x360 active Mini Player centers metadata and keeps volume', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(560, 360);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final windowController = DesktopWindowController.fallback(
      desktopRuntime: true,
    );
    await windowController.setMiniPlayerMode(true);
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        desktopWindowControllerProvider.overrideWith((ref) => windowController),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('desktopMiniPlayerVolumeSlider')),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('desktopMiniPlayerVolumeSlider')),
          )
          .width,
      greaterThan(160),
    );
    expect(find.byKey(const ValueKey('miniPlayerExitButton')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniPlayerAlwaysOnTop')), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('desktopMiniPlayerTitle')),
          )
          .textAlign,
      TextAlign.center,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('desktopMiniPlayerArtist')),
          )
          .textAlign,
      TextAlign.center,
    );
    final floatingControls = tester.getRect(
      find.byKey(const ValueKey<String>('miniPlayerFloatingWindowControls')),
    );
    final title = tester.getRect(
      find.byKey(const ValueKey<String>('desktopMiniPlayerTitle')),
    );
    final pin = tester.getRect(
      find.byKey(const ValueKey<String>('miniPlayerAlwaysOnTop')),
    );
    expect(
      floatingControls.left,
      greaterThan(
        tester
                .getSize(
                  find.byKey(
                    const ValueKey<String>('desktopMiniPlayerSurface'),
                  ),
                )
                .width *
            .8,
      ),
    );
    expect(title.overlaps(floatingControls), isFalse);
    expect(pin.left, greaterThanOrEqualTo(floatingControls.left));

    await tester.tap(
      find.byKey(const ValueKey<String>('miniPlayerAlwaysOnTop')),
    );
    await tester.pump();
    expect(windowController.miniAlwaysOnTop, isTrue);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey('desktopMiniPlayerSurface')),
      matchesGoldenFile('goldens/mini_player_active_560x360.png'),
    );
  });

  testWidgets('560x360 Mini Player preserves remote-source provenance', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(560, 360);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final windowController = DesktopWindowController.fallback(
      desktopRuntime: true,
    );
    await windowController.setMiniPlayerMode(true);
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        desktopWindowControllerProvider.overrideWith((ref) => windowController),
        songByIdProvider.overrideWith(
          (ref, songId) => Stream.value(
            songId == _remoteMetadataSong.id ? _remoteMetadataSong : null,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('remote-source-indicator')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey('desktopMiniPlayerSurface')),
      matchesGoldenFile('goldens/mini_player_remote_metadata_560x360.png'),
    );
  });

  testWidgets('560x360 radio Mini Player shows live stop-safe transport', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(560, 360);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final windowController = DesktopWindowController.fallback(
      desktopRuntime: true,
    );
    await windowController.setMiniPlayerMode(true);
    const radioPlayback = PlaybackSnapshot(
      queueSongIds: <String>[],
      currentSongId: null,
      currentIndex: null,
      playing: true,
      processingState: AudioProcessingState.ready,
      position: Duration.zero,
      duration: Duration.zero,
      bufferedPosition: Duration.zero,
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
      radioStation: RadioStationMetadata(
        stationId: 'radio-1',
        stationName: 'Test Radio',
        streamUrl: 'https://example.com/radio',
      ),
    );
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(
          desktopRuntime: true,
          playback: radioPlayback,
        ),
        desktopWindowControllerProvider.overrideWith((ref) => windowController),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(find.text('LIVE'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('desktopMiniPlayerSeekSlider')),
      findsNothing,
    );
    expect(find.byTooltip('Previous'), findsNothing);
    expect(find.byTooltip('Stop radio'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktopMiniPlayerVolumeSlider')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('undersized Mini Player blocks the active layout safely', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(392, 184);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final windowController = DesktopWindowController.fallback(
      desktopRuntime: true,
    );
    await windowController.setMiniPlayerMode(true);
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        desktopWindowControllerProvider.overrideWith((ref) => windowController),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('desktopMiniPlayerUndersized')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('desktopMiniPlayerTightPlayback')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pump(
      DesktopWindowController.resizeSettleInterval +
          const Duration(milliseconds: 1),
    );
  });

  testWidgets('Desktop resize gate blocks an invalid 799x599 workspace', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(799, 599);
    await tester.binding.setSurfaceSize(const Size(799, 599));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      return tester.binding.setSurfaceSize(null);
    });
    final windowController = DesktopWindowController.fallback(
      desktopRuntime: true,
    );
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        desktopWindowControllerProvider.overrideWith((ref) => windowController),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pump();
    await tester.pump(
      DesktopWindowController.resizeSettleInterval +
          const Duration(milliseconds: 1),
    );
    await tester.pump();

    expect(find.text('Switch to Mini Player'), findsOneWidget);
    expect(find.text('Restore Desktop Size'), findsOneWidget);
    await expectLater(
      find.byKey(const ValueKey<String>('desktopWindowTransitionGate')),
      matchesGoldenFile('goldens/desktop_resize_gate_799x599.png'),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

  testWidgets('short 799x444 Desktop resize gate keeps both actions visible', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(799, 444);
    await tester.binding.setSurfaceSize(const Size(799, 444));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      return tester.binding.setSurfaceSize(null);
    });
    final windowController = DesktopWindowController.fallback(
      desktopRuntime: true,
    );
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        desktopWindowControllerProvider.overrideWith((ref) => windowController),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pump();
    await tester.pump(
      DesktopWindowController.resizeSettleInterval +
          const Duration(milliseconds: 1),
    );
    await tester.pump();

    final switchAction = find.widgetWithText(
      FilledButton,
      'Switch to Mini Player',
    );
    final restoreAction = find.widgetWithText(
      OutlinedButton,
      'Restore Desktop Size',
    );
    expect(switchAction, findsOneWidget);
    expect(restoreAction, findsOneWidget);
    expect(tester.getRect(switchAction).top, greaterThanOrEqualTo(0));
    expect(
      tester.getRect(restoreAction).bottom,
      lessThanOrEqualTo(tester.view.physicalSize.height),
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey<String>('desktopWindowTransitionGate')),
      matchesGoldenFile('goldens/desktop_resize_gate_short_799x444.png'),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

  testWidgets('expanded Mini Player prompts before returning to Desktop View', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      return tester.binding.setSurfaceSize(null);
    });
    final windowController = DesktopWindowController.fallback(
      desktopRuntime: true,
    );
    await windowController.setMiniPlayerMode(true);
    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(desktopRuntime: true),
        desktopWindowControllerProvider.overrideWith((ref) => windowController),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pump();
    await tester.pump(
      DesktopWindowController.resizeSettleInterval +
          const Duration(milliseconds: 1),
    );
    await tester.pump();

    expect(find.text('Return to Desktop View'), findsWidgets);
    expect(find.text('Keep Mini Player'), findsOneWidget);
    await expectLater(
      find.byKey(const ValueKey<String>('desktopWindowTransitionGate')),
      matchesGoldenFile('goldens/mini_player_resize_gate_800x600.png'),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

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
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    final libraryRailTile = find.byKey(
      const ValueKey<String>('compactRailNavTile-1'),
    );
    expect(libraryRailTile, findsOneWidget);
    final librarySemantics = tester.widget<Semantics>(libraryRailTile);
    expect(librarySemantics.properties.label, 'Library');
    expect(librarySemantics.properties.onTap, isNotNull);
    expect(find.byTooltip('Library'), findsOneWidget);

    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/compact_rail_before_tooltip.png'),
    );

    final tooltipState = tester.state<TooltipState>(
      find.ancestor(of: libraryRailTile, matching: find.byType(Tooltip)),
    );
    expect(tooltipState.ensureTooltipVisible(), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/compact_rail_with_tooltip.png'),
    );

    // Advancing the clock also exposes the test environment's retrying
    // artist-info provider. Flush its initial retry before test teardown.
    await tester.pump(const Duration(milliseconds: 500));
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
        UncontrolledProviderScope(container: container, child: testNavisApp),
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

  testWidgets('phone MiniPlayerStrip rendering is pinned', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    await expectLater(
      find.byKey(const ValueKey<String>('appShellScaffold')),
      matchesGoldenFile('goldens/phone_mini_player_strip_390x844.png'),
    );
    await tester.pump(const Duration(milliseconds: 201));
  });

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
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    container.read(playerOverlayStackProvider.notifier).expand();
    await tester.pumpAndSettle();

    expect(container.read(playerSheetExpandedProvider), isTrue);
    expect(find.byType(ExpandablePlayerSheet), findsOneWidget);
  });

  testWidgets(
    'keeps deep settings route stable while resizing across layouts',
    (tester) async {
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
        UncontrolledProviderScope(container: container, child: testNavisApp),
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
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
      overrides: _authenticatedShellOverrides(desktopRuntime: true),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
        UncontrolledProviderScope(container: container, child: testNavisApp),
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

      // Re-selecting Library keeps the section it was showing.
      await tester.tap(libraryMain);
      await tester.pumpAndSettle();
      expect(find.text('Library - Liked'), findsOneWidget);
      expect(container.read(librarySectionProvider), LibrarySection.liked);
      final router = container.read(appRouterProvider);
      expect(router.state.uri.toString(), AppRoutes.librarySection('liked'));

      // So does returning from another tab.
      await tester.tap(find.byKey(const ValueKey('railNavTile-0')));
      await tester.pumpAndSettle();
      await tester.tap(libraryMain);
      await tester.pumpAndSettle();
      expect(find.text('Library - Liked'), findsOneWidget);
      expect(container.read(librarySectionProvider), LibrarySection.liked);

      // A Library location names its section.
      router.go(AppRoutes.librarySection('albums'));
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
          ..._authenticatedShellOverrides(desktopRuntime: true),
          showLikedPageProvider.overrideWithValue(true),
          showArtistsPageProvider.overrideWithValue(true),
          showPlaylistsPageProvider.overrideWithValue(true),
          showRadioPageProvider.overrideWithValue(true),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
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
    'the sidebar highlights a Library section only on the Library page',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(desktopRuntime: true),
          showRadioPageProvider.overrideWithValue(true),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();
      FontWeight? albumsWeight() => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('railLibrarySection-albums')),
              matching: find.byType(Text),
            ),
          )
          .style
          ?.fontWeight;

      await tester.tap(find.byKey(const ValueKey('railNavTile-1')));
      await tester.pumpAndSettle();
      expect(albumsWeight(), FontWeight.w700);

      final router = container.read(appRouterProvider);
      router.go(AppRoutes.album('missing-album'));
      // The album page keeps a loading animation running.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(albumsWeight(), FontWeight.w500);

      router.go(AppRoutes.library);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(albumsWeight(), FontWeight.w700);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tight vertical rail falls back to tabbed library navigation', (
    tester,
  ) async {
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
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
  });

  testWidgets('expanded player takes back priority over branch detail routes', (
    tester,
  ) async {
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
      UncontrolledProviderScope(container: container, child: testNavisApp),
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

  testWidgets('system back at Home announces the localized exit prompt', (
    tester,
  ) async {
    NavService.clearExitPrompt();
    addTearDown(NavService.clearExitPrompt);
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.text('Press back again to exit'), findsOneWidget);
  });

  testWidgets('reduced motion opens and dismisses the queue without travel', (
    tester,
  ) async {
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: UncontrolledProviderScope(
          container: container,
          child: testNavisApp,
        ),
      ),
    );
    await tester.pumpAndSettle();

    container.read(playerOverlayStackProvider.notifier).showQueue();
    await tester.pump();

    final queueTranslation = find.byKey(
      const ValueKey<String>('queueOverlayTranslation'),
    );
    expect(queueTranslation, findsOneWidget);
    expect(
      tester.widget<FractionalTranslation>(queueTranslation).translation,
      Offset.zero,
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(QueueSheet), findsNothing);
    expect(container.read(queueOverlayVisibleProvider), isFalse);
  });

  testWidgets(
    'final queue item teardown keeps exit visual and releases back immediately',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(599, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(),
          playerStateProvider.overrideWith(
            (ref) => ref.watch(_mutablePlaybackProvider),
          ),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      final router = container.read(appRouterProvider);
      router.go('/settings/cache');
      await tester.pumpAndSettle();
      container.read(playerOverlayStackProvider.notifier).expand();
      await tester.pumpAndSettle();

      container.read(_mutablePlaybackProvider.notifier).snapshot =
          const PlaybackSnapshot.idle();
      await tester.pump();

      expect(container.read(playerOverlayStackProvider), isEmpty);
      expect(find.byType(ExpandablePlayerSheet), findsOneWidget);
      expect(
        tester
            .widget<IgnorePointer>(
              find.byKey(const ValueKey<String>('playerExitIgnorePointer')),
            )
            .ignoring,
        isTrue,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Cache & Storage'), findsNothing);
      expect(find.byType(ExpandablePlayerSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'idle playback clears queue and now-playing overlays before immediate back',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(599, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(),
          playerStateProvider.overrideWith(
            (ref) => ref.watch(_mutablePlaybackProvider),
          ),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      final router = container.read(appRouterProvider);
      router.go('/settings/cache');
      await tester.pumpAndSettle();
      container.read(playerOverlayStackProvider.notifier).showQueue();
      await tester.pumpAndSettle();

      expect(
        container.read(playerOverlayStackProvider),
        const <PlayerOverlayRoute>[
          PlayerOverlayRoute.nowPlaying,
          PlayerOverlayRoute.queue,
        ],
      );

      container.read(_mutablePlaybackProvider.notifier).snapshot =
          const PlaybackSnapshot.idle();
      await tester.pump();

      expect(container.read(playerOverlayStackProvider), isEmpty);
      expect(find.text('Queue'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Cache & Storage'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('radio teardown uses the same retained non-interactive exit', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(599, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = _createContainerWithDatabase(
      overrides: <Override>[
        ..._authenticatedShellOverrides(),
        playerStateProvider.overrideWith(
          (ref) => ref.watch(_mutablePlaybackProvider),
        ),
      ],
    );
    container
        .read(_mutablePlaybackProvider.notifier)
        .snapshot = const PlaybackSnapshot(
      queueSongIds: <String>[],
      currentSongId: null,
      currentIndex: null,
      playing: true,
      processingState: AudioProcessingState.ready,
      position: Duration.zero,
      duration: Duration.zero,
      bufferedPosition: Duration.zero,
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
      radioStation: RadioStationMetadata(
        stationId: 'radio-1',
        stationName: 'Test Radio',
        streamUrl: 'https://example.com/radio',
      ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();
    container.read(playerOverlayStackProvider.notifier).expand();
    await tester.pumpAndSettle();

    container.read(_mutablePlaybackProvider.notifier).snapshot =
        const PlaybackSnapshot.idle();
    await tester.pump();

    expect(container.read(playerOverlayStackProvider), isEmpty);
    expect(find.byType(ExpandablePlayerSheet), findsOneWidget);
    expect(
      tester
          .widget<IgnorePointer>(
            find.byKey(const ValueKey<String>('playerExitIgnorePointer')),
          )
          .ignoring,
      isTrue,
    );

    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ExpandablePlayerSheet), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(ExpandablePlayerSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop lyrics overlay is Now Playing and closes on navigation and '
    'Escape',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final container = _createContainerWithDatabase(
        overrides: _authenticatedShellOverrides(desktopRuntime: true),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();
      final lyricsOverlay = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_DesktopLyricsOverlay',
      );

      container.read(playerOverlayStackProvider.notifier).expand();
      await tester.pumpAndSettle();
      expect(lyricsOverlay, findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(lyricsOverlay, findsNothing);
      expect(container.read(playerSheetExpandedProvider), isFalse);

      container.read(playerOverlayStackProvider.notifier).expand();
      await tester.pumpAndSettle();
      expect(lyricsOverlay, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(lyricsOverlay, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('re-selecting Settings scrolls its list back to the top', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 560);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();
    Finder destination(ShellBranch branch) => find
        .descendant(
          of: find.byType(NavigationBar),
          matching: find.byType(NavigationDestination),
        )
        .at(branch.index);

    await tester.tap(destination(ShellBranch.settings));
    await tester.pumpAndSettle();
    final list = find.descendant(
      of: find.byType(SettingsScreen),
      matching: find.byType(Scrollable),
    );
    await tester.drag(list.first, const Offset(0, -300));
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(list.first).position;
    expect(position.pixels, greaterThan(0));

    await tester.tap(destination(ShellBranch.settings));
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
  });

  testWidgets('re-selecting Search scrolls its list back to the top', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 560);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );
    final history = container.read(navisDatabaseProvider).historyDao;
    await tester.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await history.saveSearchQuery('query $i');
      }
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();
    Finder destination(ShellBranch branch) => find
        .descendant(
          of: find.byType(NavigationBar),
          matching: find.byType(NavigationDestination),
        )
        .at(branch.index);

    await tester.tap(destination(ShellBranch.search));
    await tester.pumpAndSettle();
    // Let the database stream deliver the recent searches.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    final list = find.text('query 1');
    expect(list, findsOneWidget);
    final scrollable = find
        .ancestor(of: list, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));

    await tester.tap(destination(ShellBranch.search));
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
  });

  testWidgets('Search focuses its field only when re-selected', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();
    Finder searchDestination() => find
        .descendant(
          of: find.byType(NavigationBar),
          matching: find.byType(NavigationDestination),
        )
        .at(ShellBranch.search.index);
    bool searchFieldFocused() => desktopCommandBlockedByTextInput();

    await tester.tap(searchDestination());
    await tester.pumpAndSettle();
    expect(searchFieldFocused(), isFalse);

    await tester.tap(searchDestination());
    await tester.pumpAndSettle();
    expect(searchFieldFocused(), isTrue);
  });

  testWidgets('switching tabs closes a menu opened inside the tab', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
    );
    await tester.pumpAndSettle();

    final homeContext = tester.element(find.byType(HomeScreen));
    unawaited(
      showDialog<void>(
        context: homeContext,
        useRootNavigator: false,
        builder: (_) => const AlertDialog(content: Text('Tab menu')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tab menu'), findsOneWidget);

    // The dialog's barrier sits inside the tab, so the bar stays tappable.
    Finder destination(IconData icon) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.byIcon(icon),
    );
    await tester.tap(destination(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(destination(Icons.home_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Tab menu'), findsNothing);
  });

  testWidgets('escape closes queue before collapsing now playing', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = _createContainerWithDatabase(
      overrides: _authenticatedShellOverrides(desktopRuntime: true),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
  });

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
        UncontrolledProviderScope(container: container, child: testNavisApp),
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

  testWidgets('escape closes collapsed queue and does not reopen now playing', (
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
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
  });

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
      overrides: _authenticatedShellOverrides(
        reachability: ServerReachabilityStatus.offline,
        desktopRuntime: true,
      ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
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

  testWidgets(
    'desktop quick-search resets stale expansion unless filter is explicit',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = _createContainerWithDatabase(
        overrides: _authenticatedShellOverrides(
          reachability: ServerReachabilityStatus.offline,
          desktopRuntime: true,
        ),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      container
          .read(searchFilterProvider.notifier)
          .select(SearchResultType.artists);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      var quickSearchField = find.byKey(
        const ValueKey('desktopQuickSearchField'),
      );
      await tester.enterText(quickSearchField, 'porcupine tree');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(container.read(searchQueryProvider), 'porcupine tree');
      expect(container.read(searchFilterProvider), isNull);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      quickSearchField = find.byKey(const ValueKey('desktopQuickSearchField'));
      await tester.enterText(quickSearchField, 'opeth');
      await tester.tap(find.widgetWithText(FilterChip, 'Songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();

      expect(container.read(searchQueryProvider), 'opeth');
      expect(container.read(searchFilterProvider), SearchResultType.songs);
    },
  );

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
      overrides: _authenticatedShellOverrides(desktopRuntime: true),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
    'compact queue dismissal restores focus to its persistent queue button',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(887, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = _createContainerWithDatabase(
        overrides: _authenticatedShellOverrides(desktopRuntime: true),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      await focusDesktopQueueButton(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
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
    },
  );

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
        overrides: _authenticatedShellOverrides(desktopRuntime: true),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
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
      overrides: _authenticatedShellOverrides(desktopRuntime: true),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: testNavisApp),
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
    'desktop player exposes Mini Player without a duplicate now-playing toggle',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = _createContainerWithDatabase(
        overrides: _authenticatedShellOverrides(desktopRuntime: true),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('desktopPlayerMiniPlayerButton')),
        findsOneWidget,
      );

      container.read(playerOverlayStackProvider.notifier).expand();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('desktopNowPlayingFocusButton')),
        findsNothing,
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
        UncontrolledProviderScope(container: container, child: testNavisApp),
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

  group('Now Playing Background beyond the Now Playing screen', () {
    const queueBackdropKey = ValueKey<String>('queueArtworkBackground');
    const desktopBackdropKey = ValueKey<String>('nowPlayingArtworkBackground');
    final coverSong = _longMetadataSong.copyWith(coverArt: const Value('c-1'));

    Future<ImageProvider<Object>> solidCover() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 4, 4),
        Paint()..color = const Color(0xFF3F7F6F),
      );
      final image = await recorder.endRecording().toImage(4, 4);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      image.dispose();
      return MemoryImage(Uint8List.view(bytes.buffer));
    }

    Future<ProviderContainer> pumpShell(
      WidgetTester tester, {
      required NowPlayingBackground background,
      bool desktop = false,
      bool flat = false,
      bool oled = false,
      ValueNotifier<NowPlayingBackground>? backgroundSetting,
      ValueNotifier<PlaybackSnapshot>? playing,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = desktop
          ? const Size(1200, 800)
          : const Size(599, 1000);
      addTearDown(tester.view.reset);
      final cover = (await tester.runAsync(solidCover))!;
      debugSeedNowPlayingTint(
        brightness: Brightness.dark,
        coverArtId: 'c-1',
        tint: const Color(0xFFD32F2F),
      );
      final container = _createContainerWithDatabase(
        overrides: <Override>[
          ..._authenticatedShellOverrides(
            desktopRuntime: desktop,
            playing: playing,
          ),
          subsonicApiProvider.overrideWithValue(null),
          nowPlayingBackgroundProvider.overrideWith((ref) {
            if (backgroundSetting == null) return background;
            void changed() => ref.invalidateSelf();
            backgroundSetting.addListener(changed);
            ref.onDispose(() => backgroundSetting.removeListener(changed));
            return backgroundSetting.value;
          }),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                themeMode: oled ? 'oled' : 'dark',
                colorStyle: 'pastel',
                flatSurfaces: flat,
              ),
            ),
          ),
          songByIdProvider.overrideWith(
            (ref, songId) => Stream.value(
              songId == coverSong.id
                  ? coverSong
                  : songId == 'song-2'
                  ? coverSong.copyWith(
                      id: 'song-2',
                      coverArt: const Value('c-2'),
                    )
                  : null,
            ),
          ),
          coverArtImageSourceProvider.overrideWith((ref, key) async => cover),
          coverColourFieldProvider.overrideWith(
            (ref, key) async =>
                CoverColourField.uniform(const Color(0xFF3F7F6F)),
          ),
          backgroundCoverColourFieldProvider.overrideWith(
            (ref, key) async =>
                CoverColourField.uniform(const Color(0xFF3F7F6F)),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: testNavisApp),
      );
      await tester.pumpAndSettle();
      return container;
    }

    Future<void> settleImages(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    Future<void> unmountShell(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pump();
    }

    Color queuePanelFill(WidgetTester tester) => tester
        .widget<Material>(
          find
              .descendant(
                of: find.byType(QueueSheet),
                matching: find.byType(Material),
              )
              .first,
        )
        .color!;

    testWidgets(
      'shell prewarms setting and track changes while collapsed; body state survives toggles',
      (tester) async {
        final background = ValueNotifier(NowPlayingBackground.plain);
        final playing = ValueNotifier(_activePlayback);
        addTearDown(background.dispose);
        addTearDown(playing.dispose);
        debugSeedNowPlayingTint(
          brightness: Brightness.dark,
          coverArtId: 'c-2',
          tint: const Color(0xFFD32F2F),
        );
        final container = await pumpShell(
          tester,
          background: background.value,
          backgroundSetting: background,
          playing: playing,
        );
        final cache = container.read(nowPlayingArtworkCacheProvider);
        expect(cache.debugRenderCount, 0);
        background.value = NowPlayingBackground.artwork;
        await tester.pumpAndSettle();
        await settleImages(tester);
        expect(container.read(playerSheetExpandedProvider), isFalse);
        expect(cache.debugRenderCount, 1);
        playing.value = _activePlayback.copyWith(
          currentSongId: 'song-2',
          currentIndex: 1,
        );
        await tester.pumpAndSettle();
        await settleImages(tester);
        expect(container.read(playerSheetExpandedProvider), isFalse);
        expect(cache.debugRenderCount, 2);
        container.read(playerOverlayStackProvider.notifier).expand();
        await tester.pumpAndSettle();
        await settleImages(tester);
        final body = find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_NowPlayingBody',
        );
        final state = tester.state(body);
        for (final mode in [
          NowPlayingBackground.tinted,
          NowPlayingBackground.plain,
          NowPlayingBackground.artwork,
        ]) {
          background.value = mode;
          await tester.pumpAndSettle();
          await settleImages(tester);
          expect(tester.state(body), same(state));
          expect(cache.debugRenderCount, 2);
        }
        await unmountShell(tester, container);
      },
    );

    testWidgets('phone queue over expanded Artwork shows the blurred cover', (
      tester,
    ) async {
      final container = await pumpShell(
        tester,
        background: NowPlayingBackground.artwork,
      );
      await settleImages(tester);
      final cache = container.read(nowPlayingArtworkCacheProvider);
      expect(container.read(playerSheetExpandedProvider), isFalse);
      expect(cache.debugRenderCount, 1);
      container.read(playerOverlayStackProvider.notifier).expand();
      await tester.pumpAndSettle();
      await settleImages(tester);
      container.read(playerOverlayStackProvider.notifier).showQueue();
      await tester.pumpAndSettle();
      await settleImages(tester);

      expect(find.byKey(queueBackdropKey), findsOneWidget);
      final published = container.read(nowPlayingPublishedBackdropProvider)!;
      final queueBackdrop = tester.widget<NowPlayingArtworkBackground>(
        find.byKey(queueBackdropKey),
      );
      expect(identical(queueBackdrop.image, published.image), isTrue);
      expect(queueBackdrop.imageKey, published.imageKey);
      expect(queueBackdrop.coverAverage, published.coverAverage);
      expect(
        find.descendant(
          of: find.byKey(queueBackdropKey),
          matching: find.byType(RawImage),
        ),
        findsOneWidget,
      );
      expect(find.byType(QueueSheet), findsOneWidget);
      expect(cache.debugRenderCount, 1);
      expect(cache.debugHitCount, greaterThanOrEqualTo(2));
      final queueState = tester.state(find.byType(QueueSheet));
      container
          .read(nowPlayingPublishedBackdropProvider.notifier)
          .clear(published.owner);
      await tester.pump();
      expect(tester.state(find.byType(QueueSheet)), same(queueState));
      container
          .read(nowPlayingPublishedBackdropProvider.notifier)
          .publish(published);
      await tester.pump();
      await settleImages(tester);
      expect(tester.state(find.byType(QueueSheet)), same(queueState));
      expect(cache.debugRenderCount, 1);
      expect(
        queuePanelFill(tester).a,
        closeTo(kNowPlayingArtworkPanelAlpha, 0.001),
      );

      container.read(playerOverlayStackProvider.notifier).hideQueue();
      await tester.pumpAndSettle();
      container.read(playerOverlayStackProvider.notifier).collapse();
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
      container.read(playerOverlayStackProvider.notifier).showQueueOnly();
      await tester.pumpAndSettle();
      expect(find.byKey(queueBackdropKey), findsNothing);
      expect(queuePanelFill(tester).a, 1);
      await unmountShell(tester, container);
    });

    testWidgets('phone queue from Home keeps the opaque sheet', (tester) async {
      final container = await pumpShell(
        tester,
        background: NowPlayingBackground.artwork,
      );
      container.read(playerOverlayStackProvider.notifier).showQueueOnly();
      await tester.pumpAndSettle();
      await settleImages(tester);

      expect(container.read(playerSheetExpandedProvider), isFalse);
      expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
      expect(find.byType(QueueSheet), findsOneWidget);
      expect(find.byKey(queueBackdropKey), findsNothing);
      expect(queuePanelFill(tester).a, 1);
      await unmountShell(tester, container);
    });

    testWidgets('phone queue keeps the opaque sheet with Art-tinted', (
      tester,
    ) async {
      final container = await pumpShell(
        tester,
        background: NowPlayingBackground.tinted,
      );
      container.read(playerOverlayStackProvider.notifier).showQueue();
      await tester.pumpAndSettle();
      await settleImages(tester);

      expect(find.byKey(queueBackdropKey), findsNothing);
      expect(queuePanelFill(tester).a, 1);
      await unmountShell(tester, container);
    });

    testWidgets('phone queue over expanded Artwork stays opaque under Flat', (
      tester,
    ) async {
      final container = await pumpShell(
        tester,
        background: NowPlayingBackground.artwork,
        flat: true,
      );
      container.read(playerOverlayStackProvider.notifier).expand();
      await tester.pumpAndSettle();
      container.read(playerOverlayStackProvider.notifier).showQueue();
      await tester.pumpAndSettle();
      expect(container.read(playerSheetExpandedProvider), isTrue);
      expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
      expect(find.byKey(queueBackdropKey), findsNothing);
      expect(queuePanelFill(tester).a, 1);
      await unmountShell(tester, container);
    });

    testWidgets('desktop lyrics view draws the Artwork background', (
      tester,
    ) async {
      final container = await pumpShell(
        tester,
        background: NowPlayingBackground.artwork,
        desktop: true,
      );
      await settleImages(tester);
      final cache = container.read(nowPlayingArtworkCacheProvider);
      expect(cache.debugRenderCount, 1);
      await tester.tap(
        find.byKey(const ValueKey<String>('desktopPlayerLyricsButton')),
      );
      await tester.pumpAndSettle();
      await settleImages(tester);

      expect(find.byKey(desktopBackdropKey), findsOneWidget);
      expect(cache.debugRenderCount, 1);
      expect(cache.debugHitCount, greaterThanOrEqualTo(1));
      expect(
        find.byKey(const ValueKey<String>('nowPlayingSurfaceTint')),
        findsOneWidget,
      );
      final header = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.byKey(
                const ValueKey<String>('desktopLyricsTrackContext'),
              ),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(
        (header.decoration as BoxDecoration).color!.a,
        closeTo(kNowPlayingArtworkPanelAlpha, 0.001),
      );
      await unmountShell(tester, container);
    });

    testWidgets('desktop lyrics view is plain with Plain', (tester) async {
      final container = await pumpShell(
        tester,
        background: NowPlayingBackground.plain,
        desktop: true,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('desktopPlayerLyricsButton')),
      );
      await tester.pumpAndSettle();
      await settleImages(tester);

      expect(find.byKey(desktopBackdropKey), findsNothing);
      final surface = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey<String>('nowPlayingSurfaceTint')),
      );
      expect(
        (surface.decoration! as BoxDecoration).color,
        Theme.of(tester.element(find.byKey(surface.key!))).colorScheme.surface,
      );
      expect((surface.decoration! as BoxDecoration).gradient, isNull);
      await unmountShell(tester, container);
    });

    for (final background in <NowPlayingBackground>[
      NowPlayingBackground.tinted,
      NowPlayingBackground.artwork,
    ]) {
      for (final oledFlat in <bool>[false, true]) {
        testWidgets('desktop lyrics ${background.name} '
            '(OLED + Flat: $oledFlat)', (tester) async {
          final container = await pumpShell(
            tester,
            background: background,
            desktop: true,
            oled: oledFlat,
            flat: oledFlat,
          );
          await tester.tap(
            find.byKey(const ValueKey<String>('desktopPlayerLyricsButton')),
          );
          await tester.pumpAndSettle();
          await settleImages(tester);
          final surface = tester.widget<AnimatedContainer>(
            find.byKey(const ValueKey<String>('nowPlayingSurfaceTint')),
          );
          final decoration = surface.decoration! as BoxDecoration;
          if (oledFlat) {
            expect(find.byKey(desktopBackdropKey), findsNothing);
            expect(decoration.color, Colors.black);
            expect(decoration.gradient, isNull);
          } else if (background == NowPlayingBackground.tinted) {
            expect(find.byKey(desktopBackdropKey), findsNothing);
            expect(decoration.gradient, isNotNull);
          } else {
            expect(find.byKey(desktopBackdropKey), findsOneWidget);
          }
          await unmountShell(tester, container);
        });
      }
    }
  });
}
