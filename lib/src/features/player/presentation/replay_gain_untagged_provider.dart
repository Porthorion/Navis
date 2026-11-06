import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/library/presentation/genre_providers.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/providers/app_providers.dart';

/// The Automatic ReplayGain level for songs without gain data, in dB: the
/// median tagged track gain of the library, or -8 dB while fewer than 20 songs
/// are tagged. One SQL pass, cached here and recomputed when a library sync
/// publishes or finishes (the epoch the genre queries also follow), not on
/// every star or play-count write.
final replayGainAutoUntaggedDbProvider = FutureProvider<double>((ref) async {
  ref.watch(genreDataEpochProvider);
  final gains = await ref
      .watch(navisDatabaseProvider)
      .libraryDao
      .trackGainMedian(maxAbsDb: replayGainMaxAbsDb);
  return automaticUntaggedGainDb(
    taggedCount: gains.count,
    median: gains.median,
  );
});

/// The untagged level playback uses: the user's fixed value, else the library
/// level (the previous one while it recomputes), else the -8 dB fallback.
double effectiveReplayGainUntaggedDb({
  required double? fixed,
  required AsyncValue<double> auto,
}) => fixed ?? auto.value ?? replayGainFallbackUntaggedDb;
