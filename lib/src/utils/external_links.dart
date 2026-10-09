import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:url_launcher/url_launcher.dart';

/// The `mailto:` link that starts an email to Navis support.
final Uri supportEmailUri = Uri(
  scheme: 'mailto',
  path: AppConstants.supportEmail,
);

/// The artist's page on Last.fm, linked from content Last.fm provided.
Uri lastFmArtistUri(String artist) => Uri.parse(
  'https://www.last.fm/music/${Uri.encodeComponent(artist.trim())}',
);

/// Opens [uri] outside Navis (browser or mail app), with a notice naming
/// [label] when the system has nothing to open it with.
Future<void> openExternalLink(
  BuildContext context,
  Uri uri, {
  required String label,
}) async {
  final l10n = AppLocalizations.of(context)!;
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    opened = false;
  }
  if (!opened && context.mounted) {
    showAppNotice(
      context,
      message: l10n.aboutLinkOpenFailed(label),
      level: AppNoticeLevel.error,
    );
  }
}
