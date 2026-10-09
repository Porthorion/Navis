import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
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
          localizationsDelegates: navisLocalizationsDelegates,
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

  testWidgets('album caption fallback follows the selected theme', (
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
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: Center(child: AlbumCard(album: _album)),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      final title = tester.widget<Text>(find.text(_album.name));
      final artist = tester.widget<Text>(find.text(_album.artistName!));
      final fade = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey<String>('albumCardTitleSurfaceFade')),
      );
      final decoration = fade.decoration as BoxDecoration;
      final gradient = decoration.gradient! as LinearGradient;

      // Without a cover id, the fallback uses the page background and
      // scheme text roles in every theme.
      expect(title.style!.color, theme.colorScheme.onSurface);
      expect(artist.style!.color, theme.colorScheme.onSurfaceVariant);
      expect(gradient.colors.last, theme.scaffoldBackgroundColor);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop hover Play is built only while hovered', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subsonicApiProvider.overrideWithValue(null),
          coverArtShapeProvider.overrideWithValue('rounded'),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: AlbumCard(album: _album, onTap: () {}),
              ),
            ),
          ),
        ),
      ),
    );
    final play = find.byKey(const ValueKey<String>('albumCardHoverPlay'));
    expect(play, findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(AlbumCard)));
    await tester.pumpAndSettle();
    expect(play, findsOneWidget);
    // No hover tooltip; screen readers still get a labelled button.
    expect(tester.widget<IconButton>(play).tooltip, isNull);
    expect(find.byType(Tooltip), findsNothing);
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Play album'), findsOneWidget);
    handle.dispose();

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(play, findsNothing);
  });
}
