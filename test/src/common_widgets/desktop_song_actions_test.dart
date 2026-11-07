import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/desktop_song_actions.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/test_theme.dart';

SongsTableData _song({required bool isExternal}) {
  return SongsTableData(
    isProvisional: isExternal,
    isExternal: isExternal,
    id: isExternal ? 'remote-song' : 'local-song',
    title: isExternal ? 'Remote song' : 'Local song',
    duration: 185,
  );
}

Widget _harness(SongsTableData song, [AppNoticeController? notices]) {
  return ProviderScope(
    overrides: [
      songStarredProvider.overrideWith((ref, songId) => Stream.value(false)),
      songDownloadStateProvider.overrideWith(
        (ref, songId) => SongDownloadState.none,
      ),
    ],
    child: MaterialApp(
      builder: notices == null
          ? null
          : (_, child) => AppNoticeScope(notifier: notices, child: child!),
      theme: testTheme(),
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: DesktopSongActions(
            song: song,
            includeDuration: true,
            keyPrefix: 'test-song',
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('wide desktop local rows expose direct actions and More', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(_song(isExternal: false)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('test-song-heart-local-song')),
      findsOneWidget,
    );
    expect(find.byType(SongDownloadStatusIcon), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('test-song-menu-local-song')),
      findsOneWidget,
    );
    expect(find.text('3:05'), findsOneWidget);
  });

  testWidgets('compact desktop local rows retain More without direct actions', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(_harness(_song(isExternal: false)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('test-song-heart-local-song')),
      findsNothing,
    );
    expect(find.byType(SongDownloadStatusIcon), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('test-song-menu-local-song')),
      findsOneWidget,
    );
  });

  testWidgets('wide remote rows keep a dimmed heart, no download or More', (
    tester,
  ) async {
    final notices = AppNoticeController();
    addTearDown(notices.dispose);
    setAdaptiveTestViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(_song(isExternal: true), notices));
    await tester.pumpAndSettle();

    final heart = find.byKey(
      const ValueKey<String>('test-song-heart-remote-song'),
    );
    expect(heart, findsOneWidget);
    expect(find.byTooltip('Like unavailable for remote songs'), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.favorite_border)).color,
      isNotNull,
    );
    expect(find.byIcon(Icons.favorite), findsNothing);
    expect(find.byType(SongDownloadStatusIcon), findsNothing);
    expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
    expect(find.text('3:05'), findsOneWidget);

    await tester.tap(heart);
    await tester.pump();
    expect(notices.notice?.message, 'Not available for remote tracks.');
  });

  testWidgets('forSongId remote rows (Search) keep the dimmed heart', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          songStarredProvider.overrideWith(
            (ref, songId) => Stream.value(false),
          ),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DesktopSongActions.forSongId(
              songId: 'ext-deezer-song-1',
              isExternal: true,
              onMore: (_) {},
              keyPrefix: 'search-song',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('search-song-heart-ext-deezer-song-1')),
      findsOneWidget,
    );
    expect(find.byTooltip('Like unavailable for remote songs'), findsOneWidget);
  });

  testWidgets('a remote-flagged song with a plain id is still dimmed', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _harness(
        const SongsTableData(
          id: 'pl-deezer-1',
          title: 'Remote song',
          isProvisional: true,
          isExternal: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Like unavailable for remote songs'), findsOneWidget);
  });

  testWidgets('compact remote rows show no heart, as library rows', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(_harness(_song(isExternal: true)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.favorite_border), findsNothing);
    expect(find.text('3:05'), findsOneWidget);
  });

  Future<void> pumpActions(
    WidgetTester tester,
    Widget actions, {
    TrackRowMode? mode,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          songStarredProvider.overrideWith(
            (ref, songId) => Stream.value(songId == 'ext-stale'),
          ),
          songDownloadStateProvider.overrideWith(
            (ref, songId) => SongDownloadState.none,
          ),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: mode == null
                  ? actions
                  : TrackRowModeScope(mode: mode, child: actions),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in <double>[1100, 1399]) {
    testWidgets('remote rows keep the heart at $width px', (tester) async {
      setAdaptiveTestViewport(tester, Size(width, 800));
      await tester.pumpWidget(_harness(_song(isExternal: true)));
      await tester.pumpAndSettle();

      expect(
        find.byTooltip('Like unavailable for remote songs'),
        findsOneWidget,
      );
    });
  }

  testWidgets('remote rows take the action width of library rows per mode', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1400, 800));
    for (final mode in TrackRowMode.values) {
      await pumpActions(
        tester,
        DesktopSongActions(song: _song(isExternal: false)),
        mode: mode,
      );
      final local = tester.getSize(find.byType(DesktopSongActions)).width;
      await pumpActions(
        tester,
        DesktopSongActions(song: _song(isExternal: true)),
        mode: mode,
      );
      final remote = tester.getSize(find.byType(DesktopSongActions)).width;
      await pumpActions(
        tester,
        DesktopSongActions.forSongId(
          songId: 'ext-deezer-song-1',
          isExternal: true,
          onMore: (_) {},
        ),
        mode: mode,
      );
      final search = tester.getSize(find.byType(DesktopSongActions)).width;
      expect(remote, local, reason: '$mode remote vs local');
      expect(search, local, reason: '$mode Search vs local');
      expect(
        find.byTooltip('Like unavailable for remote songs'),
        mode == TrackRowMode.wide ? findsOneWidget : findsNothing,
      );
    }
  });

  testWidgets('a remote heart shows the outline even with a stale star', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          songStarredProvider.overrideWith((ref, songId) => Stream.value(true)),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SongHeartButton(songId: 'ext-stale')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.favorite), findsNothing);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
  });

  testWidgets('a remote song heart is disabled and explains itself on tap', (
    tester,
  ) async {
    final notices = AppNoticeController();
    addTearDown(notices.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          songStarredProvider.overrideWith(
            (ref, songId) => Stream.value(false),
          ),
        ],
        child: MaterialApp(
          builder: (_, child) =>
              AppNoticeScope(notifier: notices, child: child!),
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SongHeartButton(songId: 'ext-deezer-song-1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final icon = tester.widget<Icon>(find.byIcon(Icons.favorite_border));
    expect(icon.color, isNotNull);
    final like = find.byTooltip('Like unavailable for remote songs');
    expect(like, findsOneWidget);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(like).flagsCollection.isEnabled,
      isNot(Tristate.isTrue),
    );
    handle.dispose();

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump();

    expect(notices.notice?.message, 'Not available for remote tracks.');
    expect(find.byIcon(Icons.favorite), findsNothing);
  });
}
