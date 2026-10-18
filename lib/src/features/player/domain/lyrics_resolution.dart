import 'package:navis/src/api/models/models.dart';

enum LyricsSource { serverSynced, serverPlain, lrclibSynced, lrclibPlain }

class LyricsResolution {
  const new({
    required this.lyrics,
    required this.source,
    this.instrumental = false,
    this.confirmedMiss = false,
    this.syncedUpgradeMiss = false,
  });

  final LyricsList lyrics;
  final LyricsSource source;
  final bool instrumental;

  /// Whether every attempted source answered without lyrics or lookup failure.
  final bool confirmedMiss;

  /// A successful LRCLIB attempt found no synced upgrade for these lyrics.
  final bool syncedUpgradeMiss;

  bool get isExternal =>
      source == LyricsSource.lrclibSynced || source == LyricsSource.lrclibPlain;
}
