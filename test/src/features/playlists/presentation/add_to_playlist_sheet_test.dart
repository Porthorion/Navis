import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _PickerLauncher extends ConsumerWidget {
  const new();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () =>
          showAddToPlaylistSheet(context, ref, const <String>['song-1']),
      child: const Text('Open picker'),
    );
  }
}

class _MockPlaylistActions extends Mock implements PlaylistActions;

class _MockApi extends Mock implements SubsonicApiClient;

const _mine = PlaylistsTableData(
  isLocal: false,
  id: 'mine',
  name: 'My Mix',
  owner: 'ME',
  songCount: 2,
);

const _picked = <PlaylistsTableData>[
  _mine,
  PlaylistsTableData(
    isLocal: false,
    id: 'smart',
    name: 'Smart Mix',
    owner: 'me',
    readOnly: true,
  ),
  PlaylistsTableData(
    isLocal: false,
    id: 'theirs',
    name: 'Their Mix',
    owner: 'alice',
  ),
];

Future<AppNoticeController> _openPicker(
  WidgetTester tester,
  PlaylistActions actions,
) async {
  final database = createTestDatabase();
  addTearDown(database.close);
  final notices = AppNoticeController();
  addTearDown(notices.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          subsonicApiProvider.overrideWithValue(null),
          playlistViewerProvider.overrideWithValue('me'),
          playlistActionsProvider.overrideWithValue(actions),
          playlistListProvider.overrideWithValue(const AsyncData(_picked)),
        ],
      ),
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppNoticeScope(notifier: notices, child: child!),
        home: const Scaffold(body: Center(child: _PickerLauncher())),
      ),
    ),
  );
  await tester.tap(find.text('Open picker'));
  await tester.pumpAndSettle();
  return notices;
}

void main() {
  setUpAll(() {
    registerFallbackValue(_mine);
    registerFallbackValue(<String>[]);
  });

  testWidgets('lists only playlists the user can edit', (tester) async {
    await _openPicker(tester, _MockPlaylistActions());

    expect(find.text('My Mix'), findsOneWidget);
    expect(find.text('Smart Mix'), findsNothing);
    expect(find.text('Their Mix'), findsNothing);
  });

  testWidgets('adds through PlaylistActions and reports the outcome', (
    tester,
  ) async {
    final actions = _MockPlaylistActions();
    when(() => actions.addSongs(any(), any())).thenAnswer((_) async => 0);
    final notices = await _openPicker(tester, actions);

    await tester.tap(find.text('My Mix'));
    await tester.pumpAndSettle();
    verify(() => actions.addSongs(_mine, const <String>['song-1'])).called(1);
    expect(notices.notice?.message, 'Added to "My Mix"');

    // Nothing was added (every song skipped): that is a failure.
    when(() => actions.addSongs(any(), any())).thenAnswer((_) async => 1);
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My Mix'));
    await tester.pumpAndSettle();
    expect(notices.notice?.message, 'Failed to add to playlist');
    expect(notices.notice?.level, AppNoticeLevel.error);

    notices.dismiss();
    expect(notices.notice, isNull);
    when(() => actions.addSongs(any(), any())).thenThrow(StateError('boom'));
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My Mix'));
    await tester.pumpAndSettle();
    expect(notices.notice?.message, 'Failed to add to playlist');
  });

  testWidgets('desktop uses a bounded playlist-picker dialog', (tester) async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await tester.binding.setSurfaceSize(const Size(1366, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            subsonicApiProvider.overrideWithValue(null),
            playlistListProvider.overrideWithValue(
              const AsyncData(<PlaylistsTableData>[]),
            ),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: Center(child: _PickerLauncher())),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Add to Playlist'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('adds to a device playlist without any server call', (
    tester,
  ) async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final api = _MockApi();
    final notices = AppNoticeController();
    addTearDown(notices.dispose);
    final id = (await tester.runAsync(() async {
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 'song-1', title: 'One'),
      ]);
      return database.playlistDao.createLocalPlaylist('Device', []);
    }))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            subsonicApiProvider.overrideWithValue(api),
            playlistViewerProvider.overrideWithValue('me'),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              AppNoticeScope(notifier: notices, child: child!),
          home: const Scaffold(body: Center(child: _PickerLauncher())),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();

    expect(find.text('On this device · No songs'), findsOneWidget);
    await tester.tap(find.text('Device'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(notices.notice?.message, 'Added to "Device"');
    final songs = await tester.runAsync(
      () => database.playlistDao.watchPlaylistSongs(id).first,
    );
    expect(songs!.map((song) => song.id), ['song-1']);
    verifyZeroInteractions(api);
    notices.dismiss();
  }, skip: !sqliteAvailable);

  testWidgets('New playlist offers the Save to server switch', (tester) async {
    await _openPicker(tester, _MockPlaylistActions());

    await tester.tap(find.text('New playlist'));
    await tester.pumpAndSettle();

    expect(find.text('Create Playlist'), findsOneWidget);
    expect(find.text('Save to server'), findsOneWidget);
  });
}
