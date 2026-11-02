import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';

extension SignOutPhaseText on SessionTransition {
  /// What teardown is doing now, or null when no sign-out is in progress.
  String? phaseText(AppLocalizations l10n) => switch (this) {
    SessionTransition.idle => null,
    SessionTransition.stoppingSync => l10n.signOutStoppingSync,
    SessionTransition.clearingData => l10n.signOutClearingData,
    SessionTransition.finishing => l10n.signOutFinishing,
  };
}
