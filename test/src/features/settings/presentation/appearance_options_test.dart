import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/features/settings/presentation/appearance_options.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/color_style_selector.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_theme.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: navisLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: buildDarkTheme(const Color(0xFF3F7F6F)),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  late AppLocalizations l10n;
  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('Now Playing Background note', () {
    Future<void> pump(
      WidgetTester tester, {
      bool oled = false,
      bool flat = false,
    }) {
      return tester.pumpWidget(
        _host(
          NowPlayingBackgroundOption(
            value: NowPlayingBackground.artwork,
            oled: oled,
            flat: flat,
            onChanged: (_) {},
          ),
        ),
      );
    }

    testWidgets('shows once under OLED + Flat only', (tester) async {
      final note = find.text(l10n.appearanceNowPlayingBackgroundOledFlatNote);
      await pump(tester, oled: true, flat: true);
      expect(note, findsOneWidget);
      await pump(tester, oled: true);
      expect(note, findsNothing);
      await pump(tester, flat: true);
      expect(note, findsNothing);
    });

    testWidgets('the selector spans the full width', (tester) async {
      await pump(tester);
      final selector = find.byKey(
        const ValueKey<String>('nowPlayingBackgroundSelector'),
      );
      final width = tester.getSize(selector).width;
      expect(width, tester.getSize(find.byType(Scaffold)).width - 32);
    });
  });

  group('accent grid under Night', () {
    testWidgets('swatches paint the raw seed with a styled accent dot', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ColorSchemeGrid(
            currentSeed: null,
            dynamicAlbumColorEnabled: false,
            customPresets: const <int>[],
            style: NavisColorStyle.night,
            onSelected: (_) {},
            onCustomColorPicked: (_) {},
            onSavePreset: (_) {},
            onDeletePreset: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fills = <int>{};
      for (final seed in <Color>[Colors.red, Colors.blue, Colors.green]) {
        final key = 'preset-${seed.toARGB32()}';
        final chip = find.byKey(ValueKey<String>('colorChip-$key'));
        final fill = find.descendant(
          of: chip,
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                (w.decoration as BoxDecoration).color?.toARGB32() ==
                    seed.toARGB32(),
          ),
        );
        expect(fill, findsOneWidget, reason: 'raw seed fill for $key');
        fills.add(seed.toARGB32());
        final dot = find.byKey(ValueKey<String>('accentDot-$key'));
        expect(dot, findsOneWidget);
        final dotBox = tester.widget<DecoratedBox>(
          find.descendant(of: dot, matching: find.byType(DecoratedBox)),
        );
        expect(
          (dotBox.decoration as BoxDecoration).color,
          styledSwatchColor(seed, NavisColorStyle.night),
        );
      }
      expect(fills, hasLength(3));
    });
  });
}
