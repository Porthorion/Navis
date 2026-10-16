import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_screen.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

class _MockPlaylistActions extends Mock implements PlaylistActions {}

class _Queue extends QueueController {
  @override
  List<String> build() => const <String>['song-1', 'song-2'];
}

Future<AppNoticeController> _openDialog(
  WidgetTester tester,
  PlaylistActions actions,
) async {
  final notices = AppNoticeController();
  addTearDown(notices.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        queueProvider.overrideWith(_Queue.new),
        subsonicApiProvider.overrideWithValue(null),
        networkTypeProvider.overrideWithValue(NetworkType.wifi),
        playlistActionsProvider.overrideWithValue(actions),
        songByIdProvider.overrideWith(
          (ref, id) => Stream.value(
            SongsTableData(
              isProvisional: false,
              isExternal: false,
              id: id,
              title: 'Track $id',
            ),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppNoticeScope(notifier: notices, child: child!),
        home: const QueueScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.byIcon(Icons.playlist_add));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'Queue mix');
  await tester.tap(find.widgetWithText(FilledButton, 'New Playlist'));
  await tester.pumpAndSettle();
  return notices;
}

void main() {
  testWidgets('Save as playlist falls back to the device without a server', (
    tester,
  ) async {
    final actions = _MockPlaylistActions();
    when(() => actions.create(any(), any(), onServer: any(named: 'onServer')))
        .thenAnswer((_) async => 'local:1');
    final notices = await _openDialog(tester, actions);

    verify(
      () => actions.create('Queue mix', const <String>[
        'song-1',
        'song-2',
      ], onServer: false),
    ).called(1);
    expect(notices.notice?.message, 'Playlist created');
    notices.dismiss();
  });

  testWidgets('Save as playlist shows a notice when creation fails', (
    tester,
  ) async {
    final actions = _MockPlaylistActions();
    when(() => actions.create(any(), any(), onServer: any(named: 'onServer')))
        .thenThrow(StateError('boom'));
    final notices = await _openDialog(tester, actions);

    expect(notices.notice?.message, 'Failed to create playlist');
    expect(notices.notice?.level, AppNoticeLevel.error);
    notices.dismiss();
  });
}
