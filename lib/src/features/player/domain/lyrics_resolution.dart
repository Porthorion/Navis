import 'package:navis/src/api/models/models.dart';

enum LyricsSource {
  serverSynced,
  serverPlain,
  lrclibSynced,
  lrclibPlain,
}

class LyricsResolution {
  const LyricsResolution({
    required this.lyrics,
    required this.source,
  });

  final LyricsList lyrics;
  final LyricsSource source;

  bool get isExternal =>
      source == LyricsSource.lrclibSynced || source == LyricsSource.lrclibPlain;
}
