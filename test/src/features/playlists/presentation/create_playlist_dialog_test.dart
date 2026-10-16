import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/playlist.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/playlists/presentation/create_playlist_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _MockApi extends Mock implements SubsonicApiClient;

class _OnlineReachability extends ServerReachabilityController {
  @override
  ServerReachabilityState build() =>
      const ServerReachabilityState(status: ServerReachabilityStatus.online);
}

class _Launcher extends ConsumerWidget {
  const new();

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilledButton(
    onPressed: () =>
        showCreatePlaylistDialog(context, ref, songIds: const ['a']),
    child: const Text('Open create'),
  );
}

Future<void> _pump(
  WidgetTester tester,
  NavisDatabase database,
  SubsonicApiClient api,
  AppNoticeController notices, {
  NetworkType network = NetworkType.wifi,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: [
          subsonicApiProvider.overrideWithValue(api),
          networkTypeProvider.overrideWithValue(network),
          serverReachabilityControllerProvider.overrideWith(
            _OnlineReachability.new,
          ),
        ],
      ),
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppNoticeScope(notifier: notices, child: child!),
        home: const Scaffold(body: Center(child: _Launcher())),
      ),
    ),
  );
}

Future<void> _create(WidgetTester tester, String name) async {
  await tester.tap(find.text('Open create'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), name);
}

/// Lets real database I/O finish, then rebuilds with its results.
Future<void> _flush(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Switch _switch(WidgetTester tester) =>
    tester.widget<Switch>(find.byType(Switch));

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'New Playlist'));
  await tester.pumpAndSettle();
  await _flush(tester);
}

void main() {
  late NavisDatabase database;
  late _MockApi api;
  late AppNoticeController notices;

  setUp(() async {
    database = createTestDatabase();
    api = _MockApi();
    notices = AppNoticeController();
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(id: 'a', title: 'A'),
    ]);
    when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .thenAnswer((_) async => const Playlist(id: 'server-1', name: 'One'));
  });

  tearDown(() async {
    notices.dispose();
    await database.close();
  });

  Future<List<PlaylistsTableData>> playlists(WidgetTester tester) async =>
      (await tester.runAsync(
        () => database.playlistDao.watchPlaylists().first,
      ))!;

  testWidgets(
    'the Save to server switch defaults on and a choice of off is remembered',
    (tester) async {
      await _pump(tester, database, api, notices);

      await _create(tester, 'One');
      expect(find.text('Save to server'), findsOneWidget);
      expect(_switch(tester).value, isTrue);
      await _submit(tester);
      verify(() => api.createPlaylist('One', songIds: const ['a'])).called(1);
      expect(notices.notice?.message, 'Playlist created');
      expect(await playlists(tester), isEmpty);

      await _create(tester, 'Two');
      await tester.tap(find.byType(Switch));
      await _flush(tester);
      expect(_switch(tester).value, isFalse);
      await _submit(tester);
      verifyNever(
        () => api.createPlaylist('Two', songIds: any(named: 'songIds')),
      );
      final created = await playlists(tester);
      expect(created.single.name, 'Two');
      expect(created.single.isLocal, isTrue);
      expect(created.single.songCount, 1);

      // The next dialog starts off, until it is turned back on.
      await tester.tap(find.text('Open create'));
      await tester.pumpAndSettle();
      expect(_switch(tester).value, isFalse);
      await tester.tap(find.byType(Switch));
      await _flush(tester);
      expect(_switch(tester).value, isTrue);
      expect(
        (await tester.runAsync(database.appSettingsDao.getSettings))!
            .playlistCreateOnServer,
        isTrue,
      );
      notices.dismiss();
    },
    skip: !sqliteAvailable,
  );

  testWidgets('offline forces the switch off and disabled without saving it', (
    tester,
  ) async {
    await _pump(tester, database, api, notices, network: NetworkType.offline);

    await _create(tester, 'Offline');
    expect(_switch(tester).value, isFalse);
    expect(_switch(tester).onChanged, isNull);
    await _submit(tester);

    verifyNever(
      () => api.createPlaylist(any(), songIds: any(named: 'songIds')),
    );
    expect((await playlists(tester)).single.isLocal, isTrue);
    expect(
      (await tester.runAsync(database.appSettingsDao.getSettings))
              ?.playlistCreateOnServer ??
          true,
      isTrue,
    );
    notices.dismiss();
  }, skip: !sqliteAvailable);

  testWidgets('a failed creation shows a notice', (tester) async {
    when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .thenThrow(StateError('boom'));
    await _pump(tester, database, api, notices);

    await _create(tester, 'One');
    await _submit(tester);

    expect(notices.notice?.message, 'Failed to create playlist');
    expect(notices.notice?.level, AppNoticeLevel.error);
  }, skip: !sqliteAvailable);
}
