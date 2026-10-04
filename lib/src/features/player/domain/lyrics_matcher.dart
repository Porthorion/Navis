import 'dart:math' as math;

import 'package:navis/src/utils/metadata_normalization.dart';

// Re-exported so importers of the lyrics matcher keep the shared normalizer.
export 'package:navis/src/utils/metadata_normalization.dart'
    show normalizeMetadata;

class LrclibMatchCandidate {
  const new({
    required this.artist,
    required this.title,
    this.album,
    this.durationSeconds,
  });

  final String artist;
  final String title;
  final String? album;
  final int? durationSeconds;
}

class LrclibMatchScore {
  const new({required this.value, this.sameEdition = false});

  final double value;

  /// Whether the titles also agree on edition qualifiers such as
  /// "(Japanese Version)", which [value] ignores. Callers prefer such a
  /// result over a different version of the same song.
  final bool sameEdition;

  bool passes([double threshold = 0.7]) => value >= threshold;
}

LrclibMatchScore scoreCandidate({
  required LrclibMatchCandidate expected,
  required LrclibMatchCandidate candidate,
}) {
  var score = 0.0;

  if (normalizeMetadata(expected.title) == normalizeMetadata(candidate.title)) {
    score += 0.4;
  }
  if (normalizeMetadata(expected.artist) ==
      normalizeMetadata(candidate.artist)) {
    score += 0.3;
  }

  final expectedDuration = expected.durationSeconds;
  final candidateDuration = candidate.durationSeconds;
  if (expectedDuration != null && candidateDuration != null) {
    if ((expectedDuration - candidateDuration).abs() <= 3) {
      score += 0.2;
    }
  }

  final expectedAlbum = expected.album;
  final candidateAlbum = candidate.album;
  if (expectedAlbum != null &&
      expectedAlbum.isNotEmpty &&
      candidateAlbum != null &&
      candidateAlbum.isNotEmpty &&
      normalizeMetadata(expectedAlbum) == normalizeMetadata(candidateAlbum)) {
    score += 0.1;
  }

  return LrclibMatchScore(
    value: math.max(0, math.min(1, score)),
    sameEdition:
        normalizeMetadataKeepingEdition(expected.title) ==
        normalizeMetadataKeepingEdition(candidate.title),
  );
}
