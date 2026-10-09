import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/presentation/playback_lyrics_content.dart';
import 'package:navis/src/providers/app_providers.dart';

class NowPlayingLyricsScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final songId = ref.watch(
      playerStateProvider.select((playback) => playback.currentSongId),
    );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.lyricsTitle)),
      body: songId == null
          ? Center(
              child: Text(
                l10n.lyricsNoneAvailable,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
            )
          : PlaybackLyricsContent(songId: songId),
    );
  }
}
