import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/features/library/presentation/genre_providers.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/providers/app_providers.dart';

/// How much of the library has ReplayGain data, and the median tagged track
/// gain. One SQL pass, cached here and recomputed when a library sync
/// publishes or finishes (the epoch the genre queries also follow), not on
/// every star or play-count write.
final replayGainLibraryGainsProvider = FutureProvider<LibraryGainStats>((
  ref,
) async {
  ref.watch(genreDataEpochProvider);
  return ref
      .watch(navisDatabaseProvider)
      .libraryDao
      .trackGainMedian(maxAbsDb: replayGainMaxAbsDb);
});

/// The Automatic ReplayGain level for songs without gain data, in dB: the
/// median tagged track gain of the library, or -8 dB while fewer than 20 songs
/// are tagged.
final replayGainAutoUntaggedDbProvider = FutureProvider<double>((ref) async {
  final gains = await ref.watch(replayGainLibraryGainsProvider.future);
  return automaticUntaggedGainDb(
    taggedCount: gains.count,
    median: gains.median,
  );
});

/// What ReplayGain does to the song playing now, for the Now Playing page:
/// null with no song, no handler, radio or ReplayGain off. The handler does
/// the deciding (read-only, so looking never changes playback); this only
/// re-asks when something that can change the answer changes, never on a
/// position tick.
final nowPlayingReplayGainProvider = Provider<ReplayGainDecision?>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  final song = ref.watch(
    playerStateProvider.select(
      // Settling a queue load decides Smart, so the loading state counts.
      (s) => (
        s.currentSongId,
        s.currentIndex,
        s.queueSongIds.length,
        s.processingState,
        s.radioStation,
      ),
    ),
  );
  if (handler == null || song.$1 == null) return null;
  ref.watch(
    appSettingsProvider.select(
      (s) => (
        s.value?.replayGainMode,
        s.value?.replayGainPreamp,
        s.value?.replayGainUntaggedDb,
      ),
    ),
  );
  ref.watch(replayGainAutoUntaggedDbProvider.select((a) => a.value));
  final decision = handler.currentReplayGainDecision;
  return decision?.db == null ? null : decision;
});

/// The untagged level playback uses: the user's fixed value, else the library
/// level (the previous one while it recomputes), else the -8 dB fallback.
double effectiveReplayGainUntaggedDb({
  required double? fixed,
  required AsyncValue<double> auto,
}) => fixed ?? auto.value ?? replayGainFallbackUntaggedDb;
