import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

/// Plain-language reason shared by download rows and failure notifications.
String downloadFailureMessage(
  AppLocalizations l10n,
  DownloadFailureReason? reason,
) => switch (reason) {
  DownloadFailureReason.notFound => l10n.downloadsFailureNotFound,
  DownloadFailureReason.serverError => l10n.downloadsFailureServerError,
  DownloadFailureReason.network => l10n.downloadsFailureNetwork,
  DownloadFailureReason.timeout => l10n.downloadsFailureTimeout,
  DownloadFailureReason.notAudio => l10n.downloadsFailureNotAudio,
  DownloadFailureReason.truncated => l10n.downloadsFailureTruncated,
  DownloadFailureReason.noSpace => l10n.downloadsFailureNoSpace,
  DownloadFailureReason.folderUnavailable =>
    l10n.downloadsFailureFolderUnavailable,
  DownloadFailureReason.permission => l10n.downloadsFailurePermission,
  DownloadFailureReason.unknown || null => l10n.downloadsFailureUnknown,
};
