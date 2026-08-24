import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _PickerLauncher extends ConsumerWidget {
  const _PickerLauncher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => showAddToPlaylistSheet(
        context,
        ref,
        const <String>['song-1'],
      ),
      child: const Text('Open picker'),
    );
  }
}

void main() {
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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
}
