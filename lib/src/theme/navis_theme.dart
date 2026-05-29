import 'package:flutter/material.dart';
import 'package:navis/src/theme/desktop_tokens.dart';

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
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: seedColor,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    ),
    extensions: const <ThemeExtension<dynamic>>[
      DesktopTokens.defaults,
    ],
  );
}

/// Build the standard dark [ThemeData] from a seed color.
ThemeData buildDarkTheme(Color seedColor) {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    ),
    extensions: const <ThemeExtension<dynamic>>[
      DesktopTokens.defaults,
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
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: baseScheme.copyWith(
      surface: Colors.black,
      onSurface: Colors.white,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: _oledContainer,
      surfaceContainer: _oledContainer,
      surfaceContainerHigh: _oledContainer,
      surfaceContainerHighest: _oledContainerHighest,
      // Ensure "on" colors for container variants stay readable
      onSurfaceVariant: baseScheme.onSurfaceVariant.withAlpha(230),
    ),
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
    extensions: const <ThemeExtension<dynamic>>[
      DesktopTokens.defaults,
    ],
  );
}

/// Preset seed colors for the color scheme picker, ordered by hue (0°→360°).
const List<NamedColor> presetColors = <NamedColor>[
  NamedColor('Red', Colors.red),
  NamedColor('Brown', Colors.brown),
  NamedColor('Orange', Colors.orange),
  NamedColor('Amber', Colors.amber),
  NamedColor('Yellow', Colors.yellow),
  NamedColor('Lime', Colors.lime),
  NamedColor('Green', Colors.green),
  NamedColor('Teal', Colors.teal),
  NamedColor('Cyan', Colors.cyan),
  NamedColor('Blue Grey', Colors.blueGrey),
  NamedColor('Blue', Colors.blue),
  NamedColor('Indigo', Colors.indigo),
  NamedColor('Deep Purple', Colors.deepPurple),
  NamedColor('Purple', Colors.purple),
  NamedColor('Pink', Colors.pink),
];

/// A named color for the scheme picker UI.
class NamedColor {
  const NamedColor(this.name, this.color);
  final String name;
  final Color color;
}
