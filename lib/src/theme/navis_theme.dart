import 'package:flutter/material.dart';
import 'package:navis/src/theme/desktop_tokens.dart';

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
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    extensions: <ThemeExtension<dynamic>>[
      DesktopTokens.defaults,
      NavisAccentColors.fromScheme(
        source: seedColor,
        colorScheme: colorScheme,
      ),
    ],
  );
}

/// Build the standard dark [ThemeData] from a seed color.
ThemeData buildDarkTheme(Color seedColor) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.dark,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    extensions: <ThemeExtension<dynamic>>[
      DesktopTokens.defaults,
      NavisAccentColors.fromScheme(
        source: seedColor,
        colorScheme: colorScheme,
      ),
    ],
  );
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
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: Colors.black,
    cardColor: _oledContainer,
    dialogTheme: const DialogThemeData(backgroundColor: _oledContainer),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.black,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: _oledContainer,
    ),
    extensions: <ThemeExtension<dynamic>>[
      DesktopTokens.defaults,
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
