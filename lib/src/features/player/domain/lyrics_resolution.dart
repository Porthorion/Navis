import 'package:navis/src/api/models/models.dart';

enum LyricsSource { serverSynced, serverPlain, lrclibSynced, lrclibPlain }

class LyricsResolution {
  const new({
    required this.lyrics,
    required this.source,
    this.confirmedMiss = false,
  });

  final LyricsList lyrics;
  final LyricsSource source;

  /// Whether every attempted source answered without lyrics or lookup failure.
  final bool confirmedMiss;

  bool get isExternal =>
      source == LyricsSource.lrclibSynced || source == LyricsSource.lrclibPlain;
}
