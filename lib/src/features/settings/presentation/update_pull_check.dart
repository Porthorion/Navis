import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
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
      // Pulls on different Library surfaces can share the same update result.
      // Serialize notice checks until the shown version has been persisted.
      final store = ref.read(updateCheckStoreProvider);
      final pending = (_noticeChecks[store] ?? Future<void>.value()).then(
        (_) => _showUpdateNotice(ref, store, info),
      );
      _noticeChecks[store] = pending;
      unawaited(pending);
    });
  } on Object catch (error, stackTrace) {
    AppLogger.error('Pull-to-refresh update check failed', error, stackTrace);
  }
}

final _noticeChecks = Expando<Future<void>>();

Future<void> _showUpdateNotice(
  WidgetRef ref,
  UpdateCheckStore store,
  UpdateInfo info,
) async {
  try {
    if (!ref.context.mounted) return;
    if (await store.readNotifiedVersion() == info.notificationKey) return;
    if (!ref.context.mounted) return;
    final context = ref.context;
    final l10n = AppLocalizations.of(context)!;
    final updateService = ref.read(updateServiceProvider);
    showAppNotice(
      context,
      message: l10n.updateAvailableNotice,
      level: AppNoticeLevel.info,
      duration: const Duration(seconds: 6),
      actionLabel: l10n.updateView,
      onAction: () {
        if (!context.mounted) return;
        unawaited(
          showUpdateDialog(context, info, updateService: updateService),
        );
      },
    );
    await store.recordNotifiedVersion(info.notificationKey);
  } on Object catch (error, stackTrace) {
    AppLogger.error('Pull-to-refresh update notice failed', error, stackTrace);
  }
}
