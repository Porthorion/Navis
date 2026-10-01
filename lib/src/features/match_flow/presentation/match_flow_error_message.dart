import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';

String matchFlowErrorMessage(AppLocalizations l10n, MatchFlowException error) {
  return switch (error.failure) {
    MatchFlowFailure.songAlreadyInFlow => l10n.matchFlowSongAlreadyInFlow,
    MatchFlowFailure.flowMissing => l10n.matchFlowMissing,
    MatchFlowFailure.masterInAnotherFlow =>
      l10n.matchFlowMasterSongInAnotherFlow,
  };
}
