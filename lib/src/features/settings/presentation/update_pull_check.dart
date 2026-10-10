import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/update_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Starts a policy-gated update check without delaying pull-to-refresh.
/// The temporary listener keeps the auto-disposed check active until it settles.
void checkForUpdatesFromPull(WidgetRef ref, {bool showNotice = false}) {
  if (!ref.context.mounted) return;
  try {
    if (!ref
        .read(integrationPolicyProvider)
        .allows(IntegrationFeature.updatesAutomatic)) {
      return;
    }
    ref.read(updateForceCheckProvider.notifier).requestForceCheck();
    ref.invalidate(updateProvider);
    ProviderSubscription<AsyncValue<UpdateInfo?>>? subscription;
    subscription = ref.listenManual(updateProvider, (_, next) {
      if (next.isLoading) return;
      subscription?.close();
      if (!ref.context.mounted || !showNotice || next.hasError) return;
      final info = next.asData?.value;
      if (info == null) return;
      final context = ref.context;
      final l10n = AppLocalizations.of(context)!;
      showAppNotice(
        context,
        message: l10n.updateAvailableNotice,
        level: AppNoticeLevel.info,
        duration: const Duration(seconds: 6),
        actionLabel: l10n.updateView,
        onAction: () {
          if (!context.mounted) return;
          unawaited(
            showUpdateDialog(
              context,
              info,
              updateService: ref.read(updateServiceProvider),
            ),
          );
        },
      );
    });
  } on Object catch (error, stackTrace) {
    AppLogger.error('Pull-to-refresh update check failed', error, stackTrace);
  }
}
