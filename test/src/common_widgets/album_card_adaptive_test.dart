import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

const _album = AlbumsTableData(
  id: 'album-1',
  name: 'A deliberately long album title for compact cards',
  artistName: 'A deliberately long artist name',
  artists: <ArtistRef>[],
  songsHydrated: true,
  isProvisional: false,
  isExternal: false,
);

void main() {
  testWidgets('compact album card remains overflow-free at 200% text', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subsonicApiProvider.overrideWithValue(null),
          coverArtShapeProvider.overrideWithValue('rounded'),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 150,
                  child: AlbumCard(album: _album, size: AlbumCardSize.compact),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text(_album.name), findsOneWidget);
    expect(find.text(_album.artistName!), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
