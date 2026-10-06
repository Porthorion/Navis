import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/home_notice_card.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/app_logger.dart';

/// The release that introduced Integrations, named on the notice.
const String kIntegrationsNoticeVersion = '1.4.3';

/// Whether Home shows [IntegrationsNoticeCard]: settings have loaded, the
/// notice was never dismissed or opened, and setup is complete. Home hides
/// the What's New row while it is true, so the two never stack.
final integrationsNoticeVisibleProvider = Provider<bool>((ref) {
  final dismissed = ref.watch(
    appSettingsProvider.select(
      (settings) => settings.asData?.value.integrationsNoticeDismissed,
    ),
  );
  if (dismissed != false) return false;
  return ref.watch(onboardingRequiredProvider) == false;
});

/// A one-time row on Home for people updating to 1.4.3: "New in 1.4.3",
/// then what Navis can now use Deezer for. Tapping it opens Settings ›
/// Integrations; tapping it or its close button records the notice as seen
/// (`integrations_notice_dismissed`), so it never returns.
///
/// Shares its frame ([HomeNoticeCard]) with the What's New row
/// (`ChangelogDiscoveryCard`), which it replaces while shown.
class IntegrationsNoticeCard extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<IntegrationsNoticeCard> createState() =>
      _IntegrationsNoticeCardState();
}

class _IntegrationsNoticeCardState
    extends ConsumerState<IntegrationsNoticeCard> {
  var _dismissed = false;

  void _markSeen() {
    if (_dismissed) return;
    setState(() => _dismissed = true);
    final dao = ref.read(navisDatabaseProvider).appSettingsDao;
    unawaited(
      dao.updateIntegrationsNoticeDismissed(dismissed: true).catchError((
        Object error,
      ) {
        AppLogger.warning('Could not record the Integrations notice: $error');
      }),
    );
  }

  void _open() {
    _markSeen();
    NavService.openSettingsPage(context, ref, SettingsPage.integrations);
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed || !ref.watch(integrationsNoticeVisibleProvider)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    return HomeNoticeCard(
      openKey: const ValueKey<String>('integrationsNoticeOpen'),
      dismissKey: const ValueKey<String>('integrationsNoticeDismiss'),
      title: l10n.integrationsNoticeTitle(kIntegrationsNoticeVersion),
      subtitle: l10n.integrationsNoticeBody,
      dismissTooltip: l10n.integrationsNoticeDismiss,
      onOpen: _open,
      onDismiss: _markSeen,
    );
  }
}
