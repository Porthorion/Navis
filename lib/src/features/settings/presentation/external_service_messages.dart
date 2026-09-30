import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/lastfm_api_client.dart';

/// User-facing reason a Last.fm API key was not accepted.
String lastFmApiKeyFailureMessage(
  LastFmApiKeyValidationResult result,
  AppLocalizations l10n,
) {
  if (result.apiErrorCode == 10 || result.statusCode == 403) {
    return l10n.configurationLastFmApiKeyInvalid;
  }
  if (result.statusCode == 429) {
    return l10n.configurationLastFmApiKeyRateLimited;
  }
  return result.message ?? l10n.configurationLastFmApiKeyValidationFailed;
}
