import 'package:material_ui/material_ui.dart';
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
    final colorScheme = Theme.of(context).colorScheme;
    final account = settings.listenBrainzUserName;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.check_circle_outline, color: colorScheme.primary),
      title: const Text('ListenBrainz connected'),
      subtitle: Text(
        account == null
            ? 'Listening activity will be sent to ListenBrainz.'
            : 'Connected as $account.',
      ),
      trailing: TextButton(
        onPressed: enabled ? onUpdate : null,
        child: const Text('Update'),
      ),
    );
  }
}
