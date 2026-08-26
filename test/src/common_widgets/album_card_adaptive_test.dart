import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_theme.dart';

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

  testWidgets('album title surface fade follows the selected theme', (
    tester,
  ) async {
    final themes = <ThemeData>[
      buildLightTheme(defaultColorSchemeSeedColor),
      buildDarkTheme(defaultColorSchemeSeedColor),
      buildOledTheme(defaultColorSchemeSeedColor),
    ];

    for (final theme in themes) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subsonicApiProvider.overrideWithValue(null),
            coverArtShapeProvider.overrideWithValue('rounded'),
          ],
          child: MaterialApp(
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: Center(child: AlbumCard(album: _album)),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      final isLight = theme.brightness == Brightness.light;
      final title = tester.widget<Text>(find.text(_album.name));
      final artist = tester.widget<Text>(find.text(_album.artistName!));
      final fade = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey<String>('albumCardTitleSurfaceFade')),
      );
      final decoration = fade.decoration as BoxDecoration;
      final gradient = decoration.gradient! as LinearGradient;

      expect(
        title.style!.color,
        isLight ? theme.colorScheme.onSurface : Colors.white,
      );
      expect(
        artist.style!.color,
        isLight ? theme.colorScheme.onSurfaceVariant : const Color(0xCCFFFFFF),
      );
      expect(gradient.colors.last, theme.scaffoldBackgroundColor);
    }
    expect(tester.takeException(), isNull);
  });
}
