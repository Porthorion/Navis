import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/artist_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/navis_tokens.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  String coverArtShape = 'square',
  String nowPlayingArtShape = 'rounded',
  String artistCardShape = 'circle',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWithValue(
          AsyncData(
            const AppSettingsModel.defaults().copyWith(
              coverArtShape: coverArtShape,
              nowPlayingArtShape: nowPlayingArtShape,
              artistCardShape: artistCardShape,
            ),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
  await tester.pump();
}

/// The decoration of the artwork's placeholder tile, which carries the same
/// shape as the image it stands in for.
BoxDecoration _tileDecoration(WidgetTester tester, Finder artwork) {
  final tile = tester.widget<Container>(
    find.descendant(of: artwork, matching: find.byType(Container)).first,
  );
  return tile.decoration! as BoxDecoration;
}

void main() {
  testWidgets('cover artwork follows Cover Art Shape at its own size', (
    tester,
  ) async {
    const artwork = CoverArtImage(
      coverArtId: null,
      width: 48,
      height: 48,
      shape: ArtworkShapeRole.cover,
    );

    await _pump(tester, artwork);
    expect(
      _tileDecoration(tester, find.byType(CoverArtImage)).borderRadius,
      BorderRadius.zero,
    );

    await _pump(tester, artwork, coverArtShape: 'rounded');
    expect(
      _tileDecoration(tester, find.byType(CoverArtImage)).borderRadius,
      NavisRadius.smAll,
    );
  });

  testWidgets('Now Playing art follows its own shape setting', (tester) async {
    const artwork = SizedBox.square(
      dimension: 300,
      child: CoverArtImage(
        coverArtId: null,
        shape: ArtworkShapeRole.nowPlaying,
      ),
    );

    await _pump(tester, artwork, coverArtShape: 'rounded');
    expect(
      _tileDecoration(tester, find.byType(CoverArtImage)).borderRadius,
      NavisRadius.mdAll,
    );

    await _pump(tester, artwork, nowPlayingArtShape: 'circle');
    expect(
      _tileDecoration(tester, find.byType(CoverArtImage)).shape,
      BoxShape.circle,
    );

    await _pump(tester, artwork, nowPlayingArtShape: 'square');
    expect(
      _tileDecoration(tester, find.byType(CoverArtImage)).borderRadius,
      BorderRadius.zero,
    );
  });

  testWidgets('artist rows follow Artist Card Shape', (tester) async {
    final card = ArtistCard(
      artist: ArtistsTableData(
        isProvisional: false,
        isExternal: false,
        id: 'ar-1',
        name: 'Artist',
        albumCount: 2,
      ),
    );

    await _pump(tester, card);
    expect(
      _tileDecoration(tester, find.byType(CoverArtImage)).shape,
      BoxShape.circle,
    );

    await _pump(tester, card, artistCardShape: 'square');
    final square = _tileDecoration(tester, find.byType(CoverArtImage));
    expect(square.shape, BoxShape.rectangle);
    expect(square.borderRadius, BorderRadius.zero);

    await _pump(tester, card, artistCardShape: 'rounded');
    expect(
      _tileDecoration(tester, find.byType(CoverArtImage)).borderRadius,
      NavisRadius.smAll,
    );
  });

  testWidgets('an explicit radius still applies without a shape role', (
    tester,
  ) async {
    await _pump(
      tester,
      const CoverArtImage(
        coverArtId: null,
        width: 48,
        height: 48,
        borderRadius: NavisRadius.lgAll,
      ),
      coverArtShape: 'rounded',
    );
    expect(
      _tileDecoration(tester, find.byType(CoverArtImage)).borderRadius,
      NavisRadius.lgAll,
    );
  });
}
