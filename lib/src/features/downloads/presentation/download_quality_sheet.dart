import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';

/// Result of the download quality picker dialog.
class DownloadQualityChoice {
  const DownloadQualityChoice({this.quality, this.format});

  /// Null means original quality (use download.view).
  final String? quality;

  /// Null means original format.
  final String? format;
}

/// Shows a bottom sheet that lets the user pick a download quality.
///
/// Returns null if cancelled, or a [DownloadQualityChoice] describing the
/// selected quality and format.
///
/// If [initialChoice] is provided, the currently-selected quality is marked
/// with a checkmark.
Future<DownloadQualityChoice?> showDownloadQualitySheet(
  BuildContext context, {
  DownloadQualityChoice? initialChoice,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showModalBottomSheet<DownloadQualityChoice>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                l10n.downloadQualityTitle,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.high_quality_outlined),
              title: Text(l10n.downloadQualityOriginal),
              subtitle: Text(l10n.downloadQualityOriginalSub),
              trailing: initialChoice != null && initialChoice.quality == null
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(
                ctx,
                const DownloadQualityChoice(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.music_note_outlined),
              title: Text(l10n.downloadQuality320),
              trailing: initialChoice?.quality == '320'
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(
                ctx,
                const DownloadQualityChoice(quality: '320', format: 'mp3'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.music_note_outlined),
              title: Text(l10n.downloadQuality192),
              trailing: initialChoice?.quality == '192'
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(
                ctx,
                const DownloadQualityChoice(quality: '192', format: 'mp3'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.music_note_outlined),
              title: Text(l10n.downloadQuality128),
              trailing: initialChoice?.quality == '128'
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(
                ctx,
                const DownloadQualityChoice(quality: '128', format: 'mp3'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
