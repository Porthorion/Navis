import 'dart:math' as math;

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
  const new({required this.value});

  final double value;

  bool passes([double threshold = 0.7]) => value >= threshold;
}

final _parenthesesRegex = RegExp(r'\([^)]*\)');
final _featRegex = RegExp(r'\b(feat\.?|ft\.?)\b.*$');
final _punctRegex = RegExp(r'[^a-z0-9\s]');
final _whitespaceRegex = RegExp(r'\s+');

String normalizeMetadata(String value) {
  final lower = value.toLowerCase().trim();
  final withoutParen = lower.replaceAll(_parenthesesRegex, ' ');
  final withoutFeat = withoutParen.replaceAll(_featRegex, ' ');
  final withoutPunct = withoutFeat.replaceAll(_punctRegex, ' ');
  return withoutPunct.replaceAll(_whitespaceRegex, ' ').trim();
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

  return LrclibMatchScore(value: math.max(0, math.min(1, score)));
}
