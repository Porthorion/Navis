import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/external_album_card.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/home/presentation/home_new_releases.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/features/settings/domain/album_title_shade.dart';
import 'package:navis/src/theme/navis_theme.dart';

final _release = HomeNewRelease(
  album: const DeezerAlbum(id: 7, title: 'Single'),
  releasedOn: DateTime(2026, 10, 1),
  artistId: 'artist-7',
  artistName: 'Artist 7',
);

Future<void> _pump(WidgetTester tester, {required bool flat}) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subsonicApiProvider.overrideWithValue(null),
        coverArtShapeProvider.overrideWithValue('rounded'),
        albumTitleShadeModeProvider.overrideWithValue(AlbumTitleShade.classic),
      ],
      child: MaterialApp(
        theme: buildDarkTheme(Colors.teal, flat: flat),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: HomeNewReleasesShelf(
              releases: <HomeNewRelease>[_release],
              horizontalPadding: 16,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('the New releases shelf keeps square cards by default', (
    tester,
  ) async {
    await _pump(tester, flat: false);

    final card = tester.getSize(find.byType(ExternalAlbumCard));
    expect(card.height, card.width);
    expect(
      find.byKey(const ValueKey<String>('albumCardCaptionBelow')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the New releases shelf reserves the caption below the art', (
    tester,
  ) async {
    await _pump(tester, flat: true);

    final card = tester.getSize(find.byType(ExternalAlbumCard));
    final context = tester.element(find.byType(ExternalAlbumCard));
    final caption = albumCardCaptionHeight(context);
    expect(card.height, closeTo(card.width + caption, 0.01));
    final shelf = tester.getSize(find.byType(HomeNewReleasesShelf));
    expect(shelf.height, greaterThanOrEqualTo(card.height));
    expect(find.text('Single'), findsOneWidget);
    expect(find.text('Artist 7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
