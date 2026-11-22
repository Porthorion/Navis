import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/settings/domain/update_delivery_resolver.dart';
import 'package:navis/src/features/settings/presentation/update_pull_check.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Secondary "Check for Updates" action for screens shown before the normal
/// app shell (sign-in, first library build). Runs the same check as About and
/// is hidden wherever About hides its update controls.
class CheckForUpdatesButton extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = ref.watch(
      integrationPolicyProvider.select(
        (policy) => policy.isServiceEnabled(IntegrationService.updates),
      ),
    );
    if (!updateUiAvailable || !allowed) return const SizedBox.shrink();
    return TextButton.icon(
      key: const ValueKey<String>('checkForUpdates'),
      onPressed: () => checkForUpdatesNow(ref),
      icon: const Icon(Icons.system_update_outlined, size: 18),
      label: Text(AppLocalizations.of(context)!.updateCheckTitle),
    );
  }
}
