import 'dart:ui';

import 'package:navis/l10n/app_localizations.dart';

/// Resolves the strings for system notifications, which are raised outside the
/// widget tree and so have no `BuildContext`.
///
/// Uses the in-app language override ([localeCode]) when set, otherwise the
/// platform language, and falls back to English when that locale is not
/// shipped.
AppLocalizations resolveNotificationLocalizations(String? localeCode) {
  final code = localeCode == null || localeCode.trim().isEmpty
      ? PlatformDispatcher.instance.locale.languageCode
      : localeCode.trim();
  final locale = Locale(code);
  if (AppLocalizations.delegate.isSupported(locale)) {
    return lookupAppLocalizations(locale);
  }
  return lookupAppLocalizations(const Locale('en'));
}
