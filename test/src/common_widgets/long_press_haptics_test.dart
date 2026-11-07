import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/artist_card.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_theme.dart';

import '../../helpers/haptics_spy.dart';
import '../../helpers/test_database.dart';

const _album = AlbumsTableData(
  id: 'album-1',
  name: 'Short',
  artistName: 'Artist',
  artists: <ArtistRef>[],
  songsHydrated: true,
  isProvisional: false,
  isExternal: false,
);

final _artist = ArtistsTableData(
  isProvisional: false,
  isExternal: false,
  id: 'ar-1',
  name: 'Artist',
  albumCount: 2,
);

Future<void> _pump(WidgetTester tester, Widget child, {ThemeData? theme}) {
  final database = createTestDatabase();
  addTearDown(database.close);
  return tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: [subsonicApiProvider.overrideWithValue(null)],
      ),
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(child: SizedBox(width: 240, child: child)),
        ),
      ),
    ),
  );
}

Future<void> _longPress(
  WidgetTester tester,
  Finder finder, {
  bool unmount = true,
}) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await gesture.up();
  await tester.pump();
  if (!unmount) return;
  // Lets the card's title and the splash timers finish.
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  final cases = <String, Widget Function(VoidCallback onLongPress)>{
    'an album card': (onLongPress) =>
        AlbumCard(album: _album, onTap: () {}, onLongPress: onLongPress),
    'a track row': (onLongPress) => AdaptiveTrackRow(
      title: 'Track',
      artist: 'Artist',
      onTap: () {},
      onLongPress: onLongPress,
    ),
    'an artist row': (onLongPress) =>
        ArtistCard(artist: _artist, onTap: () {}, onLongPress: onLongPress),
    'an artist tile': (onLongPress) => ArtistCard.grid(
      artist: _artist,
      onTap: () {},
      onLongPress: onLongPress,
    ),
  };

  for (final entry in cases.entries) {
    testWidgets('${entry.key} long press plays exactly one longPress and no '
        'framework vibration', (tester) async {
      final spy = HapticsSpy.install(tester);
      var opened = 0;
      await _pump(tester, entry.value(() => opened++));
      await _longPress(tester, find.byType(InkWell).first);
      expect(opened, 1);
      expect(await spy.take(tester), ['longPress']);
      expect(spy.takeFramework(), isEmpty);
    });

    testWidgets('${entry.key} long press is silent with Lists & Menus off', (
      tester,
    ) async {
      final spy = HapticsSpy.install(tester);
      var opened = 0;
      await _pump(tester, entry.value(() => opened++));
      NavisHaptics.prefs = HapticsPrefs.fromColumns(
        true,
        HapticCategory.listsAndMenus.bit,
      );
      await _longPress(tester, find.byType(InkWell).first);
      expect(opened, 1);
      expect(await spy.take(tester), isEmpty);
      expect(spy.takeFramework(), isEmpty);
    });
  }

  testWidgets('a tooltip long press gives no framework vibration', (
    tester,
  ) async {
    final spy = HapticsSpy.install(tester);
    await _pump(
      tester,
      IconButton(
        tooltip: 'Explain',
        icon: const Icon(Icons.info),
        onPressed: () {},
      ),
      theme: buildLightTheme(Colors.blue),
    );
    await _longPress(tester, find.byType(IconButton), unmount: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Explain'), findsOneWidget);
    expect(spy.takeFramework(), isEmpty);
    expect(await spy.take(tester), isEmpty);
  });
}
