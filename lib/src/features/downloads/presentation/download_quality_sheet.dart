import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

export 'package:navis/src/features/downloads/domain/download_preferences.dart'
    show DownloadQualityChoice;

/// Display name of a transcode format, e.g. `MP3`.
String downloadFormatLabel(String format) => format.trim().toUpperCase();

/// Display name of a download quality, e.g. "Original quality" or
/// "320 kbps MP3".
String downloadQualityLabel(
  AppLocalizations l10n,
  DownloadQualityChoice choice,
) {
  if (choice.isOriginal) return l10n.downloadQualityOriginal;
  final kbps = int.tryParse(choice.quality ?? '');
  final format = choice.format;
  if (kbps == null) return downloadFormatLabel(format ?? '');
  if (format == null) return l10n.playbackSettingsQualityKbps(kbps);
  return l10n.downloadQualityTranscoded(kbps, downloadFormatLabel(format));
}

/// The quality a finished download was stored in.
DownloadQualityChoice downloadedQualityChoice(
  CachedTracksTableData track,
  SongsTableData? song,
) {
  if (isOriginalQualityDownload(
    format: track.format,
    bitRate: track.bitRate,
    songSuffix: song?.suffix,
    songBitRate: song?.bitRate,
  )) {
    return const DownloadQualityChoice();
  }
  return DownloadQualityChoice(
    quality: '${track.bitRate}',
    format: track.format,
  );
}

/// [message] for a queued download, naming the quality when the saved
/// preference chose it without asking.
String downloadQueuedNotice(
  AppLocalizations l10n,
  String message,
  DownloadQualityChoice choice,
) {
  if (!choice.automatic) return message;
  return l10n.downloadQueuedWithQuality(
    message.replaceFirst(RegExp(r'\.$'), ''),
    downloadQualityLabel(l10n, choice),
  );
}

/// The quality to download in: the saved preference, or the user's pick from
/// the quality picker. Returns null when the picker is cancelled.
///
/// The first pick after the preference was introduced is followed by a
/// one-time question: always download in this quality? Accepting saves the
/// preference, so later downloads skip the picker. Either answer is final;
/// the setting stays changeable in Downloads settings. The download goes
/// ahead in the picked quality either way.
Future<DownloadQualityChoice?> requestDownloadQuality(
  BuildContext context,
  WidgetRef ref,
) async {
  // Read before any await: the calling widget may be gone afterwards.
  final dao = ref.read(navisDatabaseProvider).appSettingsDao;
  final preference = await dao.getDownloadQualityPreference();
  if (preference.savedChoice case final saved?) return saved;
  if (!context.mounted) return null;
  final choice = await showDownloadQualitySheet(
    context,
    format: preference.format,
  );
  if (choice == null || preference.prompted || !context.mounted) {
    return choice;
  }
  final always = await _showAlwaysDownloadPrompt(context, choice);
  await dao.updateDownloadQualityPrompted(prompted: true);
  if (always) {
    final saved = DownloadQualityPreference.fromChoice(choice);
    await dao.updateDownloadQuality(
      mode: saved.mode,
      bitRate: saved.bitRate,
      format: saved.format,
    );
  }
  return choice;
}

Future<bool> _showAlwaysDownloadPrompt(
  BuildContext context,
  DownloadQualityChoice choice,
) async {
  final l10n = AppLocalizations.of(context)!;
  final label = downloadQualityLabel(l10n, choice);
  final always = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey<String>('downloadQualityAlwaysPrompt'),
      title: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Text(l10n.downloadQualityAlwaysTitle(label)),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Text(l10n.downloadQualityAlwaysBody),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('downloadQualityAlwaysAsk'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.downloadQualityAlwaysAsk),
        ),
        FilledButton(
          key: const ValueKey<String>('downloadQualityAlwaysUse'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.downloadQualityAlwaysUse),
        ),
      ],
    ),
  );
  return always ?? false;
}

/// Shows the quality picker: original, or one of [kDownloadBitRateOptions]
/// transcoded to [format].
///
/// Returns null if cancelled, or a [DownloadQualityChoice] describing the
/// selected quality and format.
///
/// If [initialChoice] is provided, the currently-selected quality is marked
/// with a checkmark.
Future<DownloadQualityChoice?> showDownloadQualitySheet(
  BuildContext context, {
  DownloadQualityChoice? initialChoice,
  String format = 'mp3',
}) {
  final l10n = AppLocalizations.of(context)!;
  Widget picker(BuildContext ctx) => SafeArea(
    child: SingleChildScrollView(
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
            key: const ValueKey<String>('downloadQuality:original'),
            leading: const Icon(Icons.high_quality_outlined),
            title: Text(l10n.downloadQualityOriginal),
            subtitle: Text(l10n.downloadQualityOriginalSub),
            trailing: initialChoice?.isOriginal ?? false
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.pop(ctx, const DownloadQualityChoice()),
          ),
          for (final option in <DownloadQualityChoice>[
            for (final kbps in kDownloadBitRateOptions)
              DownloadQualityChoice(quality: '$kbps', format: format),
          ])
            ListTile(
              key: ValueKey<String>('downloadQuality:${option.quality}'),
              leading: const Icon(Icons.music_note_outlined),
              title: Text(downloadQualityLabel(l10n, option)),
              trailing: option.sameQualityAs(initialChoice)
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(ctx, option),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (isDesktopRuntime) {
    return showDialog<DownloadQualityChoice>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => Dialog(child: SizedBox(width: 440, child: picker(ctx))),
    );
  }
  return showModalBottomSheet<DownloadQualityChoice>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: picker,
  );
}
