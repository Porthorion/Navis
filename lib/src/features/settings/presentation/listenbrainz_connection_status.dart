import 'package:material_ui/material_ui.dart';
import 'package:dio/dio.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';

/// Compact connection state shared by ListenBrainz setup surfaces.
class ListenBrainzConnectionStatus extends StatelessWidget {
  const new({
    super.key,
    required this.settings,
    required this.onUpdate,
    this.enabled = true,
  });

  final AppSettingsModel settings;
  final VoidCallback onUpdate;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!settings.listenBrainzTokenValid) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final account = settings.listenBrainzUserName;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.check_circle_outline, color: colorScheme.primary),
      title: Text(l10n.listenBrainzConnectedTitle),
      subtitle: Text(
        account == null
            ? l10n.listenBrainzConnectedNoAccount
            : l10n.listenBrainzConnectedAs(account),
      ),
      trailing: TextButton(
        onPressed: enabled ? onUpdate : null,
        child: Text(l10n.listenBrainzUpdateToken),
      ),
    );
  }
}

/// Sanitized connect-flow errors shared by Settings and setup.
String listenBrainzConnectionError(AppLocalizations l10n, Object error) {
  if (error is IntegrationBlockedException ||
      error is DioException && error.error is IntegrationBlockedException) {
    return l10n.configurationListenBrainzOnlineServicesOff;
  }
  if (error is ListenBrainzInvalidTokenException) {
    return l10n.configurationListenBrainzTokenInvalid;
  }
  if (error is ListenBrainzRateLimitedException) {
    return l10n.configurationListenBrainzRateLimited;
  }
  if (error is ListenBrainzUnavailableException && error.statusCode != null) {
    return l10n.configurationListenBrainzUnavailableHttp(error.statusCode!);
  }
  return l10n.configurationListenBrainzUnavailable;
}
