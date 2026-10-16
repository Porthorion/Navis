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

  /// Every attempted source answered without lyrics, with no lookup failure.
  final bool confirmedMiss;

  bool get isExternal =>
      source == LyricsSource.lrclibSynced || source == LyricsSource.lrclibPlain;
}
