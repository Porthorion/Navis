import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/home_notice_card.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/app_logger.dart';

/// A one-time row on Home that invites updated users to review setup for the
/// new appearance options.
///
/// Opening it starts the onboarding review and acknowledges nothing: only
/// Finish clears the "New" tags. Its close button hides the row for this
/// release (`dismissCard`) at once, leaving the tags in place.
class SetupHighlightsCard extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<SetupHighlightsCard> createState() =>
      _SetupHighlightsCardState();
}

class _SetupHighlightsCardState extends ConsumerState<SetupHighlightsCard> {
  var _dismissed = false;

  void _dismiss() {
    if (_dismissed) return;
    setState(() => _dismissed = true);
    unawaited(
      ref.read(setupHighlightsServiceProvider).dismissCard().catchError((
        Object error,
      ) {
        AppLogger.warning('Could not record the setup highlights card: $error');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final release = ref.watch(setupWhatsNewReleaseProvider);
    if (_dismissed ||
        release == null ||
        !ref.watch(setupHighlightsCardVisibleProvider)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    return HomeNoticeCard(
      openKey: const ValueKey<String>('setupHighlightsOpen'),
      dismissKey: const ValueKey<String>('setupHighlightsDismiss'),
      title: l10n.setupHighlightsCardTitle,
      subtitle: l10n.setupHighlightsCardBody,
      icon: Icons.palette_outlined,
      dismissTooltip: l10n.setupHighlightsCardDismiss,
      onOpen: () => NavService.openOnboardingReview(context, ref),
      onDismiss: _dismiss,
    );
  }
}
