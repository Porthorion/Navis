import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/desktop_song_actions.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

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

Widget _harness(SongsTableData song) {
  return ProviderScope(
    overrides: [
      songStarredProvider.overrideWith((ref, songId) => Stream.value(false)),
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

  testWidgets('remote rows expose no local-server actions', (tester) async {
    setAdaptiveTestViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(_song(isExternal: true)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.favorite_border), findsNothing);
    expect(find.byType(SongDownloadStatusIcon), findsNothing);
    expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
    expect(find.text('3:05'), findsOneWidget);
  });
}
