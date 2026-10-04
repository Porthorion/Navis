import 'package:material_ui/material_ui.dart';
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
