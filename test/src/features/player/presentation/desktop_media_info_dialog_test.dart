import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/desktop_media_info_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_theme.dart';

const _snapshot = PlaybackSnapshot(
  queueSongIds: <String>['s1'],
  currentSongId: 's1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration.zero,
  duration: Duration(minutes: 3),
  bufferedPosition: Duration.zero,
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

const _song = SongsTableData(
  id: 's1',
  title: 'Aurora',
  artistName: 'Some Artist',
  albumName: 'Some Album',
  suffix: 'flac',
  bitRate: 900,
  sampleRate: 44100,
  size: 30 * 1024 * 1024,
  duration: 180,
  playCount: 7,
  recordingMbid: 'mbid-recording',
  isProvisional: false,
  isExternal: false,
);

const _bareSong = SongsTableData(
  id: 's1',
  title: 'Bare',
  isProvisional: false,
  isExternal: false,
);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    SongsTableData song = _song,
    bool admin = false,
    Map<String, dynamic>? details,
    MediaItem? mediaItem,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerStateProvider.overrideWithValue(_snapshot),
          songByIdProvider.overrideWith((ref, id) => Stream.value(song)),
          songServerDetailsProvider.overrideWith((ref, id) async => details),
          serverUserIsAdminProvider.overrideWith((ref) async => admin),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream.value(mediaItem),
          ),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDesktopMediaInfoDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows track, file and library data and closes on Escape', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Media info'), findsOneWidget);
    expect(find.text('Aurora'), findsOneWidget);
    expect(find.text('FLAC'), findsOneWidget);
    expect(find.text('30.0 MB'), findsOneWidget);
    expect(find.text('mbid-recording'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktopMediaInfoDialog')), findsNothing);
  });

  testWidgets('hides empty fields and sections', (tester) async {
    await pump(tester, song: _bareSong);
    expect(find.text('Bare'), findsOneWidget);
    expect(find.text('Track'), findsOneWidget);
    for (final hidden in <String>[
      'File',
      'Library data',
      'Transcoding',
      'Server',
      'Bitrate',
      'Year',
      'MusicBrainz recording ID',
    ]) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }
  });

  testWidgets('Server section is admin-only', (tester) async {
    const details = <String, dynamic>{'path': '/music/a/aurora.flac'};
    await pump(tester, details: details);
    expect(find.text('Server'), findsNothing);
    expect(find.text('/music/a/aurora.flac'), findsNothing);
  });

  testWidgets('admins get the Server section with the file path', (
    tester,
  ) async {
    await pump(
      tester,
      admin: true,
      details: const <String, dynamic>{
        'path': '/music/a/aurora.flac',
        'bitDepth': 24,
        'channelCount': 2,
        'bpm': 120,
        'comment': 'hello',
      },
    );
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('/music/a/aurora.flac'), findsOneWidget);
    expect(find.text('24'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('shows source versus streamed format when transcoding', (
    tester,
  ) async {
    await pump(
      tester,
      mediaItem: const MediaItem(
        id: 's1',
        title: 'Aurora',
        extras: <String, dynamic>{
          'transcodingApplied': true,
          'resolvedFormat': 'opus',
          'resolvedBitRate': 128,
        },
      ),
    );
    expect(find.text('Transcoding'), findsOneWidget);
    expect(find.text('FLAC • 900 Kb/s'), findsOneWidget);
    expect(find.text('OPUS • 128 Kb/s'), findsOneWidget);
  });

  testWidgets('no transcode section for a direct stream', (tester) async {
    await pump(tester);
    expect(find.text('Transcoding'), findsNothing);
  });

  testWidgets('rows carry accessibility labels', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    expect(find.bySemanticsLabel('Format: FLAC'), findsOneWidget);
    expect(find.bySemanticsLabel('Play count: 7'), findsOneWidget);
    handle.dispose();
  });
}
