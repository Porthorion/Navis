import 'package:flutter/material.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Default seed used when no explicit color has been saved.
const Color defaultColorSchemeSeedColor = Colors.white;

/// Resolve a nullable persisted seed value to the effective seed color.
Color resolveColorSchemeSeedColor(int? seed) {
  return seed != null ? Color(seed) : defaultColorSchemeSeedColor;
}

/// Brand/decorative accent colors that preserve the user's effective seed.
///
/// Material widgets should keep using [ColorScheme] roles. This extension is
/// for Navis-specific marks such as logos and splash/progress decoration where
/// the selected accent should be shown exactly when it remains readable.
@immutable
class NavisAccentColors extends ThemeExtension<NavisAccentColors> {
  const NavisAccentColors({
    required this.source,
    required this.brand,
    required this.brandTrack,
  });

  factory NavisAccentColors.fromScheme({
    required Color source,
    required ColorScheme colorScheme,
  }) {
    final brand = _resolveBrandColor(source, colorScheme);
    return NavisAccentColors(
      source: source,
      brand: brand,
      brandTrack: brand.withValues(alpha: 0.14),
    );
  }

  final Color source;
  final Color brand;
  final Color brandTrack;

  // Matches Flutter's Theme.of(context) lookup convention for extensions.
  // ignore: prefer_constructors_over_static_methods
  static NavisAccentColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NavisAccentColors>() ??
        NavisAccentColors.fromScheme(
          source: theme.colorScheme.primary,
          colorScheme: theme.colorScheme,
        );
  }

  static Color _resolveBrandColor(Color source, ColorScheme colorScheme) {
    if (_contrastRatio(source, colorScheme.surface) >= 3.0) {
      return source;
    }
    if (_contrastRatio(colorScheme.primary, colorScheme.surface) >= 3.0) {
      return colorScheme.primary;
    }
    return colorScheme.onSurface;
  }

  static double _contrastRatio(Color a, Color b) {
    final aLuminance = a.computeLuminance();
    final bLuminance = b.computeLuminance();
    final lighter = aLuminance > bLuminance ? aLuminance : bLuminance;
    final darker = aLuminance > bLuminance ? bLuminance : aLuminance;
    return (lighter + 0.05) / (darker + 0.05);
  }

  @override
  NavisAccentColors copyWith({
    Color? source,
    Color? brand,
    Color? brandTrack,
  }) {
    return NavisAccentColors(
      source: source ?? this.source,
      brand: brand ?? this.brand,
      brandTrack: brandTrack ?? this.brandTrack,
    );
  }

  @override
  NavisAccentColors lerp(
    ThemeExtension<NavisAccentColors>? other,
    double t,
  ) {
    if (other is! NavisAccentColors) {
      return this;
    }
    return NavisAccentColors(
      source: Color.lerp(source, other.source, t) ?? source,
      brand: Color.lerp(brand, other.brand, t) ?? brand,
      brandTrack: Color.lerp(brandTrack, other.brandTrack, t) ?? brandTrack,
    );
  }
}

/// Resolve a persisted theme mode string to a Flutter [ThemeMode].
///
/// 'oled' maps to [ThemeMode.dark] since OLED is a dark variant — the
/// actual OLED-specific [ThemeData] is selected at the call site.
ThemeMode resolveThemeMode(String mode) {
  return switch (mode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    'oled' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => ThemeMode.dark,
  };
}

/// Build the light [ThemeData] from a seed color.
ThemeData buildLightTheme(Color seedColor) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.light,
    // Tonal spot retains the selected accent while keeping text, headings,
    // and interactive roles sufficiently dark against light surfaces.
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
  );
  return _buildNavisTheme(colorScheme, seedColor);
}

/// Build the standard dark [ThemeData] from a seed color.
ThemeData buildDarkTheme(Color seedColor) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.dark,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  return _buildNavisTheme(colorScheme, seedColor);
}

// OLED surface constants – extracted for consistency.
const Color _oledContainer = Color(0xFF0A0A0A);
const Color _oledContainerHighest = Color(0xFF121212);

/// Build an OLED (pure black) [ThemeData] from a seed color.
///
/// Uses true `#000000` backgrounds and surfaces for maximum battery savings
/// on AMOLED screens.
ThemeData buildOledTheme(Color seedColor) {
  final baseScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.dark,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  final colorScheme = baseScheme.copyWith(
    surface: Colors.black,
    onSurface: Colors.white,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: _oledContainer,
    surfaceContainer: _oledContainer,
    surfaceContainerHigh: _oledContainer,
    surfaceContainerHighest: _oledContainerHighest,
    // Ensure "on" colors for container variants stay readable
    onSurfaceVariant: baseScheme.onSurfaceVariant.withAlpha(230),
  );
  return _buildNavisTheme(colorScheme, seedColor, oled: true);
}

/// Bundled UI typeface (see `assets/fonts/`).
const String navisFontFamily = 'Inter';

const List<FontFeature> _tabularFigures = <FontFeature>[
  FontFeature.tabularFigures(),
];

/// Weight and tracking adjustments applied on top of the Material 3 type
/// scale.
///
/// Sizes and line heights stay at the Material values so layouts and
/// mixed-script lines keep their metrics. Material's positive tracking was
/// tuned for Roboto and reads loose in Inter, so it is tightened here. Large
/// sizes use negative tracking and heavier weights for display headings.
/// Small styles, which carry durations and counts, use tabular figures so
/// numbers do not jitter as they change.
const TextTheme _navisTextTheme = TextTheme(
  displayLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -1.2),
  displayMedium: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.9),
  displaySmall: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.6),
  headlineLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
  headlineMedium: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.4),
  headlineSmall: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.3),
  titleLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.2),
  titleMedium: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0),
  titleSmall: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0),
  bodyLarge: TextStyle(letterSpacing: 0),
  bodyMedium: TextStyle(letterSpacing: 0),
  bodySmall: TextStyle(letterSpacing: 0.1, fontFeatures: _tabularFigures),
  labelLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.1),
  labelMedium: TextStyle(
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
    fontFeatures: _tabularFigures,
  ),
  labelSmall: TextStyle(
    fontWeight: FontWeight.w500,
    letterSpacing: 0.3,
    fontFeatures: _tabularFigures,
  ),
);

/// Shared theme construction for every scheme.
///
/// The public builders only choose a [ColorScheme]; typography, component
/// themes and extensions are defined once here so light, dark and OLED
/// cannot drift apart.
ThemeData _buildNavisTheme(
  ColorScheme colorScheme,
  Color seedColor, {
  bool oled = false,
}) {
  // Outlines on secondary controls use the softer variant role so they
  // separate controls without competing with filled primary actions.
  final softOutline = BorderSide(color: colorScheme.outlineVariant);
  final disabledOutline = BorderSide(
    color: colorScheme.onSurface.withValues(alpha: 0.12),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: colorScheme.brightness,
    colorScheme: colorScheme,
    fontFamily: navisFontFamily,
    textTheme: _navisTextTheme,
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? disabledOutline
              : softOutline,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: WidgetStateBorderSide.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const BorderSide(color: Colors.transparent);
        }
        return states.contains(WidgetState.disabled)
            ? disabledOutline
            : softOutline;
      }),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: oled ? _oledContainer : colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(borderRadius: NavisRadius.mdAll),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: NavisRadius.mdAll),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      // Only the base border is themed: a themed enabled/focused border
      // would override fields that deliberately pass InputBorder.none.
      border: OutlineInputBorder(borderRadius: NavisRadius.mdAll),
    ),
    scaffoldBackgroundColor: oled ? Colors.black : null,
    cardColor: oled ? _oledContainer : null,
    dialogTheme: oled
        ? const DialogThemeData(backgroundColor: _oledContainer)
        : null,
    appBarTheme: oled
        ? const AppBarTheme(
            backgroundColor: Colors.black,
            surfaceTintColor: Colors.transparent,
          )
        : null,
    bottomNavigationBarTheme: oled
        ? const BottomNavigationBarThemeData(backgroundColor: Colors.black)
        : null,
    navigationBarTheme: oled
        ? const NavigationBarThemeData(
            backgroundColor: Colors.black,
            surfaceTintColor: Colors.transparent,
          )
        : null,
    bottomSheetTheme: oled
        ? const BottomSheetThemeData(backgroundColor: _oledContainer)
        : null,
    extensions: <ThemeExtension<dynamic>>[
      NavisTokens.forScheme(colorScheme, oled: oled),
      NavisAccentColors.fromScheme(
        source: seedColor,
        colorScheme: colorScheme,
      ),
    ],
  );
}

/// Preset seed colors for the color scheme picker, ordered as a readable
/// gradient from warm through cool, vivid, and neutral accents.
const List<NamedColor> presetColors = <NamedColor>[
  NamedColor('Deep Orange', Colors.deepOrange),
  NamedColor('Orange', Colors.orange),
  NamedColor('Amber', Colors.amber),
  NamedColor('Yellow', Colors.yellow),
  NamedColor('Lime', Colors.lime),
  NamedColor('Green', Colors.green),
  NamedColor('Light Green', Colors.lightGreen),
  NamedColor('Teal', Colors.teal),
  NamedColor('Cyan', Colors.cyan),
  NamedColor('Light Blue', Colors.lightBlue),
  NamedColor('Blue', Colors.blue),
  NamedColor('Indigo', Colors.indigo),
  NamedColor('Deep Purple', Colors.deepPurple),
  NamedColor('Purple', Colors.purple),
  NamedColor('Pink', Colors.pink),
  NamedColor('Red', Colors.red),
  NamedColor('Brown', Colors.brown),
  NamedColor('Blue Grey', Colors.blueGrey),
  NamedColor('Grey', Colors.grey),
];

/// A named color for the scheme picker UI.
class NamedColor {
  const NamedColor(this.name, this.color);
  final String name;
  final Color color;
}
