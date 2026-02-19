import 'package:navis/l10n/app_localizations.dart';

String normalizeServerUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.endsWith('/')) {
    return trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

Uri? parseServerUrl(String rawUrl) {
  final normalized = normalizeServerUrl(rawUrl);
  final uri = Uri.tryParse(normalized);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
    return null;
  }
  return uri;
}

bool isInsecureHttpUrl(String rawUrl) {
  final uri = parseServerUrl(rawUrl);
  return uri?.scheme.toLowerCase() == 'http';
}

String? validateServerUrl(String? rawUrl, AppLocalizations l10n) {
  if (rawUrl == null || rawUrl.trim().isEmpty) {
    return l10n.loginValidationServerUrlRequired;
  }

  final uri = parseServerUrl(rawUrl);
  if (uri == null) {
    return l10n.loginValidationServerUrlInvalid;
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return l10n.loginValidationServerUrlInvalid;
  }

  return null;
}
