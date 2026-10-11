import 'dart:math' as math;

import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';

/// The active [NavisColorStyle] and how it treats colours Navis derives from
/// artwork: the Home cover wash and the art-tinted Now Playing background.
///
/// Artwork itself is never recoloured; only the fields drawn from it are.
@immutable
class NavisColorStyleData extends ThemeExtension<NavisColorStyleData> {
  const new({
    required this.style,
    required this.dark,
    this.flat = false,
    this.flatAreas = const FlatAreas(),
    this.oled = false,
    this.accentHue = seaGlassHue,
    this.adjustment = ColorAdjustment.none,
    this.controls = NavisControlColor.accent,
  });

  final NavisColorStyle style;
  final ColorAdjustment adjustment;
  final NavisControlColor controls;

  /// Whether the theme is dark (Dark or OLED).
  final bool dark;

  /// Whether the Flat Surfaces switch is on, independent of [flatAreas].
  /// Orthogonal to the theme mode and [style].
  final bool flat;

  final FlatAreas flatAreas;

  bool get flatSurfaces => flat && flatAreas.surfaces;
  bool get flatNowPlaying => flat && flatAreas.nowPlaying;
  bool get flatArtworkText => flat && flatAreas.artworkText;

  /// Whether the theme is OLED (pure black backgrounds). Implies [dark].
  final bool oled;

  /// HCT hue of the scheme's accent; tints [artworkScrim] for Pastel and
  /// Immersive.
  final double accentHue;

  @visibleForTesting
  static const NavisColorStyleData neutralDark = NavisColorStyleData(
    style: NavisColorStyle.neutral,
    dark: true,
  );

  // Matches Flutter's Theme.of(context) lookup convention for extensions.
  // ignore: prefer_constructors_over_static_methods
  static NavisColorStyleData of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NavisColorStyleData>() ??
        NavisColorStyleData(
          style: NavisColorStyle.neutral,
          dark: theme.brightness == Brightness.dark,
          flat: false,
        );
  }

  /// Near-black colour for the legibility scrims behind white text over
  /// artwork. Neutral keeps pure black; the other styles tint it with their
  /// own hue (tone 6-8, so white text contrast is unchanged in practice).
  Color get artworkScrim {
    return switch (style) {
      NavisColorStyle.neutral => Colors.black,
      NavisColorStyle.pastel => hct(pastelDuskHue(accentHue), 10, 7),
      NavisColorStyle.immersive => hct(accentHue, 12, 6),
      NavisColorStyle.night => hct(62, 10, 6),
    };
  }

  /// Map a colour sampled from artwork into the style.
  ///
  /// Neutral keeps [raw] at zero vividness, otherwise scaling only chroma.
  /// The other styles keep the colour's hue
  /// (Night moves it into the warm range) and place it at the style's tone
  /// and chroma, so a yellow cover gives a soft butter or umber field rather
  /// than olive.
  Color adaptArtColor(Color raw) {
    if (style == NavisColorStyle.neutral) {
      if (adjustment.vividness == 0) return raw;
      final source = Hct.fromInt(raw.toARGB32());
      return hct(
        source.hue,
        source.chroma * adjustment.chromaFactor,
        source.tone,
      );
    }
    final source = Hct.fromInt(raw.toARGB32());
    final achromatic = source.chroma < 6;
    final (maxChroma, minTone, maxTone) = switch ((style, dark)) {
      (NavisColorStyle.pastel, true) => (12.0, 26.0, 34.0),
      (NavisColorStyle.pastel, false) => (13.0, 88.0, 94.0),
      (NavisColorStyle.immersive, true) => (32.0, 16.0, 24.0),
      (NavisColorStyle.immersive, false) => (40.0, 78.0, 88.0),
      (NavisColorStyle.night, true) => (20.0, 20.0, 30.0),
      (NavisColorStyle.night, false) => (24.0, 84.0, 90.0),
      (NavisColorStyle.neutral, _) => (0.0, 0.0, 100.0),
    };
    final shift = adjustment.toneShift(dark: dark);
    final tone = source.tone.clamp(
      (minTone + shift).clamp(2.0, 99.0),
      (maxTone + shift).clamp(2.0, 99.0),
    );
    var chroma = achromatic
        ? source.chroma
        : source.chroma.clamp(0.0, maxChroma * adjustment.chromaFactor);
    var hue = style == NavisColorStyle.night && !achromatic
        ? nightHue(source.hue)
        : source.hue;
    if (dark && !achromatic && isWarmHue(hue)) {
      switch (style) {
        case NavisColorStyle.pastel:
          // Warm hues turn brown at dark tones: blend toward the plum dusk
          // so an orange cover reads as rose or plum, like Pastel's scheme.
          // Yellows are the muddiest, so they travel further (60% up to 85%).
          final yellowness = ((hue - 60) / 40).clamp(0.0, 1.0);
          hue = _blendHue(hue, pastelDuskHue(hue), 0.6 + 0.25 * yellowness);
        case NavisColorStyle.immersive:
          // Keep the hue but stop dark warm colours from reading as brown:
          // lower chroma gives wine or mahogany instead of saturated umber.
          if (tone < 35) {
            chroma = math.min(chroma, 22);
          }
        case NavisColorStyle.neutral || NavisColorStyle.night:
          break;
      }
    }
    return hct(mudGuardHue(hue, tone), chroma, tone);
  }

  /// Rotate [from] toward [to] along the shorter arc by [t] (0-1).
  static double _blendHue(double from, double to, double t) {
    var delta = (to - from) % 360;
    if (delta > 180) {
      delta -= 360;
    }
    return from + delta * t;
  }

  /// Opacity of the background veil over the Home cover wash. Lower values
  /// let more of the wash show; the styled washes are already softened by
  /// [adaptArtColor], so they need less veil than raw cover colours.
  double artWashVeil({required bool subtle}) {
    return switch ((style, dark)) {
      (NavisColorStyle.neutral, false) => subtle ? 0.9 : 0.84,
      (NavisColorStyle.neutral, true) => subtle ? 0.78 : 0.66,
      (NavisColorStyle.pastel, false) => subtle ? 0.6 : 0.42,
      (NavisColorStyle.pastel, true) => subtle ? 0.64 : 0.46,
      (NavisColorStyle.immersive, false) => subtle ? 0.74 : 0.56,
      (NavisColorStyle.immersive, true) => subtle ? 0.62 : 0.42,
      (NavisColorStyle.night, false) => subtle ? 0.8 : 0.66,
      (NavisColorStyle.night, true) => subtle ? 0.7 : 0.52,
    };
  }

  /// Opacity of the art tint at the top of the Now Playing background.
  double get nowPlayingTintAlpha {
    return switch (style) {
      NavisColorStyle.neutral => 0.4,
      NavisColorStyle.pastel => 0.75,
      NavisColorStyle.immersive => 0.85,
      NavisColorStyle.night => 0.7,
    };
  }

  /// Veil laid over the blurred cover of the Artwork Now Playing background
  /// so [surface]'s on-colour text stays readable (aims for 5.0:1, the WCAG
  /// 4.5:1 minimum plus a margin, on any cover).
  ///
  /// Dark themes darken with [artworkScrim] (OLED heavier, so it still reads
  /// as OLED); light themes wash the cover out with [surface].
  ///
  /// This is the fixed veil, used until the cover's average colour is known;
  /// [nowPlayingArtworkVeilRange] bounds the adaptive one.
  Color nowPlayingArtworkVeil(Color surface) =>
      nowPlayingArtworkVeilBase(surface)
          .withValues(alpha: dark ? (oled ? 0.8 : 0.68) : 0.68);

  /// Main Play always uses a solid fill, independent of style and mode.
  /// The flag identifies the solid action role, including White Controls.
  bool get solidPlayButton => true;

  /// Solid primary action shared by every Play button.
  Color playButtonFill(ColorScheme scheme) =>
      controls == NavisControlColor.white ? Colors.white : scheme.primary;

  /// Glyph on the solid action; White Controls use deep accent ink.
  Color onPlayButtonFill(ColorScheme scheme) =>
      controls == NavisControlColor.white
      ? _controlInk(scheme)
      : scheme.onPrimary;

  /// Secondary fill: 50% white on Light keeps more of the page tint;
  /// Dark uses 80% so deep accent glyphs retain 4.5:1 even on black OLED.
  Color tonalControlFill(ColorScheme scheme) =>
      controls == NavisControlColor.white
      ? Color.alphaBlend(
          Colors.white.withValues(alpha: dark ? 0.8 : 0.5),
          scheme.surface,
        )
      : scheme.secondaryContainer;

  Color onTonalControlFill(ColorScheme scheme) =>
      controls == NavisControlColor.white
      ? _controlInk(scheme)
      : scheme.onSecondaryContainer;

  /// Optional hairline for white controls on light tinted chrome.
  Color? get controlEdge => controls == NavisControlColor.white && !dark
      ? hct(accentHue, 24, 35).withValues(alpha: 0.25)
      : null;

  /// [playButtonStyle] for the ambient theme.
  static ButtonStyle playStyleOf(
    BuildContext context, {
    bool circular = false,
  }) =>
      of(context)
          .playButtonStyle(Theme.of(context).colorScheme, circular: circular);

  /// [tonalButtonStyle] for the ambient theme.
  static ButtonStyle tonalStyleOf(
    BuildContext context, {
    bool circular = false,
    bool? selected,
  }) => of(context).tonalButtonStyle(
    Theme.of(context).colorScheme,
    circular: circular,
    selected: selected,
  );

  /// Button style for the solid action: [playButtonFill] with
  /// [onPlayButtonFill] and the Light [controlEdge]. Every Play button and the
  /// FAB take it, so the role cannot drift per widget; [circular] keeps an
  /// icon button round under every Corner Style.
  ButtonStyle playButtonStyle(ColorScheme scheme, {bool circular = false}) =>
      _roleStyle(
        playButtonFill(scheme),
        onPlayButtonFill(scheme),
        circular: circular,
      );

  /// Button style for secondary filled controls: [tonalControlFill] with
  /// [onTonalControlFill]. Flutter's FilledButton theme cannot tell tonal from
  /// solid, so tonal buttons pass this.
  ///
  /// A toggle passes [selected]. On is the tonal fill; off is the neutral
  /// role, an outlined button with no fill. Material's off container
  /// (`surfaceContainerHighest`) sits within 0.1 contrast of the tonal fill on
  /// tinted pages, which left on and off indistinguishable.
  ButtonStyle tonalButtonStyle(
    ColorScheme scheme, {
    bool circular = false,
    bool? selected,
  }) => _roleStyle(
    tonalControlFill(scheme),
    onTonalControlFill(scheme),
    circular: circular,
    toggle: selected == null ? null : scheme,
  );

  ButtonStyle _roleStyle(
    Color fill,
    Color ink, {
    required bool circular,
    ColorScheme? toggle,
  }) {
    T? pick<T>(Set<WidgetState> states, T? on, T? off) =>
        states.contains(WidgetState.disabled)
        ? null
        : toggle == null || states.contains(WidgetState.selected)
        ? on
        : off;
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => pick(states, fill, Colors.transparent),
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => pick(states, ink, toggle?.onSurfaceVariant),
      ),
      iconColor: WidgetStateProperty.resolveWith(
        (states) => pick(states, ink, toggle?.onSurfaceVariant),
      ),
      side: controlEdgeSide == null && toggle == null
          ? null
          : WidgetStateProperty.resolveWith(
              (states) => pick(
                states,
                controlEdgeSide,
                BorderSide(color: toggle?.outlineVariant ?? Colors.transparent),
              ),
            ),
    ).merge(circular ? NavisShapeData.circularIconButtonStyle : null);
  }

  /// [controlEdge] as a border side, for hand-built white fills.
  BorderSide? get controlEdgeSide {
    final edge = controlEdge;
    return edge == null ? null : BorderSide(color: edge);
  }

  Color _controlInk(ColorScheme scheme) {
    final source = Hct.fromInt(scheme.primary.toARGB32());
    return hct(accentHue, source.chroma.clamp(24.0, 48.0), 35);
  }

  /// Opaque colour of the Artwork veil.
  Color nowPlayingArtworkVeilBase(Color surface) =>
      dark ? artworkScrim : surface;

  /// Smallest and largest veil alpha the adaptive Artwork veil may use.
  (double, double) get nowPlayingArtworkVeilRange =>
      dark ? (oled ? (0.72, 0.92) : (0.30, 0.80)) : (0.58, 0.88);

  /// Colour for confirmed, positive states (a completed download, a
  /// successful connection test). Neutral keeps the original greens; the
  /// other styles use a green at the same tone as their accents so it reads
  /// as part of the palette.
  Color get success {
    return switch ((style, dark)) {
      (NavisColorStyle.neutral, true) => const Color(0xFF81C995),
      (NavisColorStyle.neutral, false) => const Color(0xFF2E7D32),
      (NavisColorStyle.pastel, true) => hct(150, 22, 86),
      (NavisColorStyle.pastel, false) => hct(150, 24, 46),
      (NavisColorStyle.immersive, true) => hct(150, 48, 80),
      (NavisColorStyle.immersive, false) => hct(150, 48, 40),
      (NavisColorStyle.night, true) => hct(125, 30, 80),
      (NavisColorStyle.night, false) => hct(125, 36, 40),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is NavisColorStyleData &&
      other.style == style &&
      other.dark == dark &&
      other.flat == flat &&
      other.flatAreas == flatAreas &&
      other.oled == oled &&
      other.accentHue == accentHue &&
      other.adjustment == adjustment &&
      other.controls == controls;

  @override
  int get hashCode => Object.hash(
    style,
    dark,
    flat,
    flatAreas,
    oled,
    accentHue,
    adjustment,
    controls,
  );

  @override
  NavisColorStyleData copyWith({
    NavisColorStyle? style,
    bool? dark,
    bool? flat,
    FlatAreas? flatAreas,
    bool? oled,
    double? accentHue,
    ColorAdjustment? adjustment,
    NavisControlColor? controls,
  }) {
    return NavisColorStyleData(
      style: style ?? this.style,
      dark: dark ?? this.dark,
      flat: flat ?? this.flat,
      flatAreas: flatAreas ?? this.flatAreas,
      oled: oled ?? this.oled,
      accentHue: accentHue ?? this.accentHue,
      adjustment: adjustment ?? this.adjustment,
      controls: controls ?? adjustment?.controls ?? this.controls,
    );
  }

  @override
  NavisColorStyleData lerp(
    ThemeExtension<NavisColorStyleData>? other,
    double t,
  ) {
    if (other is! NavisColorStyleData) {
      return this;
    }
    return t < 0.5 ? this : other;
  }
}
