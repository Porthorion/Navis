import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';

/// Application strings and the standalone design libraries' translations.
///
/// Keep this separate from generated localization output, which still includes
/// the framework's legacy Material and Cupertino delegates.
const navisLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  AppLocalizations.delegate,
  ...GlobalMaterialLocalizations.delegates,
];
