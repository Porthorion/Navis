import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/routing/desktop_layout.dart';

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
  Widget picker(BuildContext ctx) => SafeArea(
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
          onTap: () => Navigator.pop(ctx, const DownloadQualityChoice()),
        ),
        for (final option in <({String quality, String label})>[
          (quality: '320', label: l10n.downloadQuality320),
          (quality: '192', label: l10n.downloadQuality192),
          (quality: '128', label: l10n.downloadQuality128),
        ])
          ListTile(
            leading: const Icon(Icons.music_note_outlined),
            title: Text(option.label),
            trailing: initialChoice?.quality == option.quality
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.pop(
              ctx,
              DownloadQualityChoice(quality: option.quality, format: 'mp3'),
            ),
          ),
        const SizedBox(height: 8),
      ],
    ),
  );
  if (isDesktopRuntime) {
    return showDialog<DownloadQualityChoice>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => Dialog(
        child: SizedBox(width: 440, child: picker(ctx)),
      ),
    );
  }
  return showModalBottomSheet<DownloadQualityChoice>(
    context: context,
    useRootNavigator: true,
    builder: picker,
  );
}
