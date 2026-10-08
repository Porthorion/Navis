import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/flat_band_tone.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/theme/navis_tokens.dart';

const _seed = Color(0xFF009688);

CoverColourField _field() => CoverColourField(const <Color>[
  Color(0xFFD32F2F),
  Color(0xFFD32F2F),
  Color(0xFF1976D2),
  Color(0xFFD32F2F),
  Color(0xFF388E3C),
  Color(0xFF1976D2),
  Color(0xFF388E3C),
  Color(0xFF388E3C),
  Color(0xFF1976D2),
]);

Future<ThemeData> _pump(
  WidgetTester tester, {
  required bool flat,
  required NavisColorStyle style,
  CoverColourField? field,
}) async {
  final theme = buildDarkTheme(_seed, style: style, flat: flat);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        coverColourFieldProvider.overrideWith((ref, id) async => field),
      ],
      child: MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: SizedBox(
            width: 300,
            height: 200,
            child: ShowcaseColourWash(coverArtId: 'cover-1'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return theme;
}

Future<ThemeData> _pumpBand(
  WidgetTester tester, {
  required NavisColorStyle style,
  CoverColourField? field,
  bool reduceMotion = true,
  void Function(CaptionTint tint)? onTint,
}) async {
  final theme = buildDarkTheme(_seed, style: style, flat: true);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        coverColourFieldProvider.overrideWith((ref, id) async => field),
      ],
      child: MaterialApp(
        theme: theme,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: ShowcaseFlatBand(
              coverArtId: 'cover-1',
              builder: (context, tint) {
                onTint?.call(tint);
                return const SizedBox(height: 120);
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return theme;
}

void main() {
  testWidgets('wash retains cached colour while its new revision loads', (
    tester,
  ) async {
    sharedCoverColourFieldCache.clear();
    addTearDown(sharedCoverColourFieldCache.clear);
    final old = _field();
    sharedCoverColourFieldCache.put('cover', old);
    final gate = Completer<CoverColourField?>();
    final requested = <(String, int)>[];
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coverColourFieldProvider.overrideWith((ref, key) {
            requested.add(key);
            return key.$2 == 0 ? Future.value(old) : gate.future;
          }),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(_seed, flat: true),
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: revision,
              builder: (context, rev, _) => SizedBox(
                width: 300,
                height: 200,
                child: ShowcaseColourWash(
                  coverArtId: 'cover',
                  coverArtRevision: rev,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Color fill() =>
        (tester
                    .widget<DecoratedBox>(
                      find.byKey(
                        const ValueKey<String>('home-showcase-wash-flat'),
                      ),
                    )
                    .decoration
                as BoxDecoration)
            .color!;
    final oldFill = fill();
    revision.value = 1;
    await tester.pump();
    expect(fill(), oldFill);
    expect(requested, [('cover', 0), ('cover', 1)]);
    gate.complete(CoverColourField.uniform(const Color(0xFF1976D2)));
    await tester.pumpAndSettle();
    expect(fill(), isNot(oldFill));
  });

  const bandKey = ValueKey<String>('home-showcase-flat-band');
  const flatFill = ValueKey<String>('home-showcase-wash-flat');

  for (final style in NavisColorStyle.values) {
    testWidgets('Flat ${style.name} paints one solid adapted average', (
      tester,
    ) async {
      final theme = await _pump(
        tester,
        flat: true,
        style: style,
        field: _field(),
      );

      expect(
        find.byType(CustomPaint).evaluate().where((e) {
          final w = e.widget as CustomPaint;
          return w.painter is CoverColourFieldPainter;
        }),
        isEmpty,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('home-showcase-wash')),
          matching: find.byType(DecoratedBox),
        ),
        // Only the solid panel itself: no gradient veil.
        findsOneWidget,
      );
      final box =
          tester.widget<DecoratedBox>(find.byKey(flatFill)).decoration
              as BoxDecoration;

      final data = theme.extension<NavisColorStyleData>()!;
      final cells = _field().colors;
      final average = Color.from(
        alpha: 1,
        red: cells.fold<double>(0, (s, c) => s + c.r) / cells.length,
        green: cells.fold<double>(0, (s, c) => s + c.g) / cells.length,
        blue: cells.fold<double>(0, (s, c) => s + c.b) / cells.length,
      );
      var adapted = data.adaptArtColor(average);
      if (Hct.fromInt(adapted.toARGB32()).chroma < 6) {
        adapted = Color.lerp(
          adapted,
          theme.colorScheme.secondaryContainer,
          .25,
        )!;
      }
      final expected = Color.alphaBlend(
        adapted.withValues(alpha: 1 - data.artWashVeil(subtle: false)),
        theme.scaffoldBackgroundColor,
      );
      expect(box.color, expected);
      expect(box.borderRadius, NavisRadius.xlAll);
      // Inset to the content margins, not full-bleed.
      expect(tester.getTopLeft(find.byKey(flatFill)).dx, NavisSpace.md);
      expect(
        tester.getSize(find.byKey(flatFill)).width,
        300 - 2 * NavisSpace.md,
      );
    });
  }

  testWidgets('Flat without a cover is the plain background', (tester) async {
    final theme = await _pump(
      tester,
      flat: true,
      style: NavisColorStyle.pastel,
    );
    expect(
      (tester.widget<DecoratedBox>(find.byKey(flatFill)).decoration
              as BoxDecoration)
          .color,
      theme.scaffoldBackgroundColor,
    );
  });

  for (final style in NavisColorStyle.values) {
    testWidgets('Flat ${style.name} grey cover takes the style chroma floor', (
      tester,
    ) async {
      final theme = await _pump(
        tester,
        flat: true,
        style: style,
        field: CoverColourField(List<Color>.filled(9, const Color(0xFF808080))),
      );
      final data = theme.extension<NavisColorStyleData>()!;
      final adapted = Color.lerp(
        data.adaptArtColor(const Color(0xFF808080)),
        theme.colorScheme.secondaryContainer,
        0.25,
      )!;
      final expected = Color.alphaBlend(
        adapted.withValues(alpha: 1 - data.artWashVeil(subtle: false)),
        theme.scaffoldBackgroundColor,
      );
      final box =
          tester.widget<DecoratedBox>(find.byKey(flatFill)).decoration
              as BoxDecoration;
      expect(box.color, expected);
    });
  }

  testWidgets('Flat off keeps the shaded mesh and veil', (tester) async {
    await _pump(
      tester,
      flat: false,
      style: NavisColorStyle.pastel,
      field: _field(),
    );
    expect(find.byKey(flatFill), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home-showcase-wash')),
        matching: find.byType(DecoratedBox),
      ),
      findsWidgets,
    );
  });

  for (final style in NavisColorStyle.values) {
    testWidgets('Flat ${style.name} phone band is a full-bleed opaque fill', (
      tester,
    ) async {
      late CaptionTint seen;
      final theme = await _pumpBand(
        tester,
        style: style,
        field: _field(),
        onTint: (tint) => seen = tint,
      );
      final data = theme.extension<NavisColorStyleData>()!;
      final cells = _field().colors;
      final average = Color.from(
        alpha: 1,
        red: cells.fold<double>(0, (s, c) => s + c.r) / cells.length,
        green: cells.fold<double>(0, (s, c) => s + c.g) / cells.length,
        blue: cells.fold<double>(0, (s, c) => s + c.b) / cells.length,
      );
      final grey =
          Hct.fromInt(data.adaptArtColor(average).toARGB32()).chroma < 6;
      final expected = captionTintFor(
        flatBandSample(
          grey
              ? Color.lerp(average, theme.colorScheme.secondaryContainer, .25)!
              : average,
          data,
        ),
        data,
        adapted: true,
      );

      final band = tester.widget<ColoredBox>(find.byKey(bandKey));
      expect(band.color.a, 1);
      expect(band.color, expected.fill);
      expect(seen, expected);
      // Edge to edge and sized by its content; no rounded corners.
      expect(tester.getTopLeft(find.byKey(bandKey)).dx, 0);
      expect(
        tester.getSize(find.byKey(bandKey)),
        Size(
          tester.view.physicalSize.width / tester.view.devicePixelRatio,
          120,
        ),
      );
      expect(find.byType(DecoratedBox), findsNothing);
      expect(find.byKey(flatFill), findsNothing);
    });
  }

  testWidgets('Flat phone band grey cover takes the style chroma floor', (
    tester,
  ) async {
    const grey = Color(0xFF808080);
    final theme = await _pumpBand(
      tester,
      style: NavisColorStyle.pastel,
      field: CoverColourField(List<Color>.filled(9, grey)),
    );
    final data = theme.extension<NavisColorStyleData>()!;
    final expected = captionTintFor(
      flatBandSample(
        Color.lerp(grey, theme.colorScheme.secondaryContainer, 0.25)!,
        data,
      ),
      data,
      adapted: true,
    );
    expect(tester.widget<ColoredBox>(find.byKey(bandKey)).color, expected.fill);
  });

  testWidgets('Flat phone band without a cover uses the page background', (
    tester,
  ) async {
    final theme = await _pumpBand(tester, style: NavisColorStyle.pastel);
    expect(
      tester.widget<ColoredBox>(find.byKey(bandKey)).color,
      theme.scaffoldBackgroundColor,
    );
  });

  testWidgets('Flat phone band glides between covers unless motion is off', (
    tester,
  ) async {
    final theme = buildDarkTheme(
      _seed,
      style: NavisColorStyle.pastel,
      flat: true,
    );
    final ids = ValueNotifier<String>('a');
    addTearDown(ids.dispose);
    Future<void> pumpWith({required bool reduce}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coverColourFieldProvider.overrideWith(
              (ref, id) async => CoverColourField(
                List<Color>.filled(
                  9,
                  id.$1 == 'a'
                      ? const Color(0xFFD32F2F)
                      : const Color(0xFF1976D2),
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: theme,
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduce),
              child: ValueListenableBuilder<String>(
                valueListenable: ids,
                builder: (context, id, _) => Scaffold(
                  body: ShowcaseFlatBand(
                    coverArtId: id,
                    builder: (context, tint) => const SizedBox(height: 50),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final reduce in <bool>[false, true]) {
      ids.value = 'a';
      await pumpWith(reduce: reduce);
      final before = tester.widget<ColoredBox>(find.byKey(bandKey)).color;
      ids.value = 'b';
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = tester.widget<ColoredBox>(find.byKey(bandKey)).color;
      await tester.pumpAndSettle();
      final after = tester.widget<ColoredBox>(find.byKey(bandKey)).color;
      expect(after, isNot(before));
      if (reduce) {
        expect(mid, after);
      } else {
        expect(mid, isNot(after));
      }
    }
  });
}
