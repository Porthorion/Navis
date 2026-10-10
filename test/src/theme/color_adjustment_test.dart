import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/caption_tint_resolver.dart';
import 'package:navis/src/features/home/presentation/cover_colour_worker.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/settings/presentation/color_style_selector.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';

Hct _hct(Color c) => Hct.fromInt(c.toARGB32());

void main() {
  test('swatches carry tuning while default Neutral keeps the raw seed', () {
    const seed = Color(0xFF0066FF);
    expect(styledSwatchColor(seed, NavisColorStyle.neutral), seed);
    for (final style in NavisColorStyle.values) {
      for (final adj in [
        const ColorAdjustment(vividness: 5),
        const ColorAdjustment(depth: -5),
      ]) {
        expect(
          styledSwatchColor(seed, style, adjustment: adj),
          buildStyledColorScheme(
            seed: seed,
            brightness: Brightness.dark,
            style: style,
            adjustment: adj,
          ).primary,
        );
      }
    }
  });

  test('adjustments are const, bounded values with stable equality', () {
    expect(
      const ColorAdjustment(vividness: 99, depth: -99),
      const ColorAdjustment(vividness: 5, depth: -5),
    );
    expect(
      const ColorAdjustment(vividness: -99, depth: 99),
      const ColorAdjustment(vividness: -5, depth: 5),
    );
    // The default constructor itself is the contract under test.
    // ignore: use_named_constants
    expect(const ColorAdjustment(), ColorAdjustment.none);
    expect(
      const ColorAdjustment(vividness: 3).hashCode,
      const ColorAdjustment(vividness: 3).hashCode,
    );
    expect(const ColorAdjustment(depth: 1), isNot(ColorAdjustment.none));
  });

  test('artwork follows vividness and depth in styled tone windows', () {
    const raw = Color(0xFF0066FF);
    for (final style in NavisColorStyle.values) {
      for (final dark in [false, true]) {
        final base = NavisColorStyleData(style: style, dark: dark);
        final muted = base.copyWith(
          adjustment: const ColorAdjustment(vividness: -5),
        );
        final vivid = base.copyWith(
          adjustment: const ColorAdjustment(vividness: 5),
        );
        expect(
          _hct(vivid.adaptArtColor(raw)).chroma,
          greaterThan(_hct(muted.adaptArtColor(raw)).chroma),
          reason: '$style dark=$dark',
        );
        final lighter = base.copyWith(
          adjustment: const ColorAdjustment(depth: -5),
        );
        final deeper = base.copyWith(
          adjustment: const ColorAdjustment(depth: 5),
        );
        if (style == NavisColorStyle.neutral) {
          expect(base.adaptArtColor(raw), raw);
          expect(lighter.adaptArtColor(raw), raw);
          expect(deeper.adaptArtColor(raw), raw);
        } else {
          expect(
            _hct(deeper.adaptArtColor(raw)).tone,
            lessThan(_hct(lighter.adaptArtColor(raw)).tone),
          );
        }
        expect(muted.artworkScrim, base.artworkScrim);
        expect(base.copyWith(), base);
        expect(base, isNot(muted));
        expect(base.lerp(muted, 0.49), base);
        expect(base.lerp(muted, 0.5), muted);
      }
    }
  });

  test('OLED Now Playing tint retains the existing tone cap', () {
    for (final style in NavisColorStyle.values) {
      for (final depth in [-5, 5]) {
        final data = NavisColorStyleData(
          style: style,
          dark: true,
          oled: true,
          adjustment: ColorAdjustment(vividness: 5, depth: depth),
        );
        final decoration = nowPlayingSurfaceDecoration(
          tintColor: const Color(0xFF0066FF),
          colorStyle: data,
          surfaceColor: Colors.black,
        );
        final top = decoration.gradient!.colors.first;
        expect(
          _hct(top).tone,
          lessThanOrEqualTo(kNowPlayingOledMaxTintTone + 0.5),
        );
      }
    }
  });

  test(
    'inline and isolate caption workers carry both adjustments and memo keys',
    () async {
      clearCaptionTintMemo();
      addTearDown(clearCaptionTintMemo);
      final inline = InlineCoverColourWorker();
      final isolate = IsolateCoverColourWorker();
      addTearDown(inline.dispose);
      addTearDown(isolate.dispose);
      const raw = Color(0xFF0066FF);
      const base = NavisColorStyleData(
        style: NavisColorStyle.pastel,
        dark: false,
      );
      final adjustments = [
        ColorAdjustment.none,
        const ColorAdjustment(vividness: -5),
        const ColorAdjustment(vividness: 5),
        const ColorAdjustment(depth: -5),
        const ColorAdjustment(depth: 5),
      ];
      final fills = <Color>[];
      for (final adj in adjustments) {
        final data = base.copyWith(adjustment: adj);
        expect(peekCaptionTint(raw, data), isNull);
        expect(
          await isolate.captionTint(raw, data),
          await inline.captionTint(raw, data),
        );
        final tint = await resolveCaptionTint(isolate, raw, data);
        expect(peekCaptionTint(raw, data), same(tint));
        fills.add(tint.fill);
      }
      expect(fills.toSet(), hasLength(adjustments.length));
    },
  );

  test('pure black and white roles and text tones stay unchanged', () {
    final scheme = buildStyledColorScheme(
      seed: Colors.blue,
      brightness: Brightness.light,
    ).copyWith(primary: Colors.white, secondary: Colors.black);
    final adjusted = adjustColorScheme(
      scheme,
      const ColorAdjustment(vividness: 5, depth: -5),
      dark: false,
      oled: false,
    );
    expect(adjusted.primary, Colors.white);
    expect(adjusted.secondary, Colors.black);
    expect(adjusted.onSurface, scheme.onSurface);
  });
}
