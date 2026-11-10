/// What Auto theme mode follows to decide between light and dark.
abstract final class AutoThemeSource {
  /// The device's light/dark setting (the default).
  static const device = 'device';

  /// A daily dark window the user sets; outside it the theme is light.
  static const schedule = 'schedule';

  static bool isValid(Object? value) => value == device || value == schedule;

  /// Default dark window: 8:00 PM to 7:00 AM.
  static const defaultDarkStartMinutes = 20 * 60;
  static const defaultDarkEndMinutes = 7 * 60;
}

/// The light or dark side of Auto, as stored in `auto_looks_applied_mode`.
abstract final class AutoMode {
  static const light = 'light';
  static const dark = 'dark';

  static bool isValid(Object? value) => value == light || value == dark;

  static String of({required bool isDark}) => isDark ? dark : light;
}
