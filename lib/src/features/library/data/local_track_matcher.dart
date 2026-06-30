import 'dart:math' as math;

import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/lyrics_matcher.dart';

const int kLocalTrackMatcherSnapshotYieldChunkSize = 1500;
const double kLocalTrackMatcherMinimumScore = 0.75;
const double kLocalTrackMatcherMinimumFieldScore = 0.75;
const double kLocalTrackMatcherAmbiguousDelta = 0.03;

class TrackMatchQuery {
  const TrackMatchQuery({
    required this.title,
    required this.artist,
    this.album,
    this.durationSeconds,
    this.recordingMbid,
  });

  final String title;
  final String artist;
  final String? album;
  final int? durationSeconds;
  final String? recordingMbid;
}

class TrackMatchCandidate {
  const TrackMatchCandidate({
    required this.song,
    required this.normalizedTitle,
    required this.normalizedArtist,
    required this.normalizedAlbum,
    this.recordingMbid,
    this.tableSong,
  });

  factory TrackMatchCandidate.fromTableSong(SongsTableData song) {
    final songObj = Song(
      id: song.id,
      title: song.title,
      album: song.albumName,
      albumId: song.albumId,
      artist: song.artistName,
      artistId: song.artistId,
      track: song.track,
      discNumber: song.discNumber,
      duration: song.duration,
      bitRate: song.bitRate,
      sampleRate: song.sampleRate,
      contentType: song.contentType,
      suffix: song.suffix,
      size: song.size,
      coverArt: song.coverArt,
      starred: song.starred,
      userRating: song.userRating,
      playCount: song.playCount,
      created: song.createdAt,
      replayGain:
          song.replayGainTrackGain == null &&
              song.replayGainAlbumGain == null &&
              song.replayGainTrackPeak == null &&
              song.replayGainAlbumPeak == null
          ? null
          : ReplayGain(
              trackGain: song.replayGainTrackGain,
              albumGain: song.replayGainAlbumGain,
              trackPeak: song.replayGainTrackPeak,
              albumPeak: song.replayGainAlbumPeak,
            ),
    );
    return TrackMatchCandidate(
      song: songObj,
      recordingMbid: song.recordingMbid,
      tableSong: song,
      normalizedTitle: normalizeMetadata(song.title),
      normalizedArtist: normalizeMetadata(song.artistName ?? ''),
      normalizedAlbum: normalizeMetadata(song.albumName ?? ''),
    );
  }

  factory TrackMatchCandidate.fromSong(Song song) {
    return TrackMatchCandidate(
      song: song,
      normalizedTitle: normalizeMetadata(song.title),
      normalizedArtist: normalizeMetadata(song.artist ?? ''),
      normalizedAlbum: normalizeMetadata(song.album ?? ''),
    );
  }

  final Song song;
  final String? recordingMbid;
  final SongsTableData? tableSong;
  final String normalizedTitle;
  final String normalizedArtist;
  final String normalizedAlbum;
}

class TrackMatchResult {
  const TrackMatchResult._({
    required this.status,
    this.song,
    this.tableSong,
  });

  const TrackMatchResult.matched({
    required Song this.song,
    this.tableSong,
  }) : status = TrackMatchStatus.matched;

  const TrackMatchResult.unmatched()
    : status = TrackMatchStatus.unmatched,
      song = null,
      tableSong = null;

  const TrackMatchResult.ambiguous()
    : status = TrackMatchStatus.ambiguous,
      song = null,
      tableSong = null;

  final TrackMatchStatus status;
  final Song? song;
  final SongsTableData? tableSong;

  bool get isMatched => status == TrackMatchStatus.matched && song != null;
}

enum TrackMatchStatus { matched, unmatched, ambiguous }

class LocalTrackMatchSnapshot {
  const LocalTrackMatchSnapshot._({
    required this.all,
    required this.byNormalizedTitle,
  });

  static Future<LocalTrackMatchSnapshot> fromSongsAsync(
    List<SongsTableData> songs,
  ) async {
    final all = <TrackMatchCandidate>[];
    for (var index = 0; index < songs.length; index++) {
      all.add(TrackMatchCandidate.fromTableSong(songs[index]));
      if ((index + 1) % kLocalTrackMatcherSnapshotYieldChunkSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    final byTitle = <String, List<TrackMatchCandidate>>{};
    for (var index = 0; index < all.length; index++) {
      final candidate = all[index];
      final title = candidate.normalizedTitle;
      if (title.isEmpty) continue;
      byTitle.putIfAbsent(title, () => <TrackMatchCandidate>[]).add(candidate);
      if ((index + 1) % kLocalTrackMatcherSnapshotYieldChunkSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return LocalTrackMatchSnapshot._(
      all: List<TrackMatchCandidate>.unmodifiable(all),
      byNormalizedTitle: {
        for (final entry in byTitle.entries)
          entry.key: List<TrackMatchCandidate>.unmodifiable(entry.value),
      },
    );
  }

  final List<TrackMatchCandidate> all;
  final Map<String, List<TrackMatchCandidate>> byNormalizedTitle;

  List<TrackMatchCandidate> candidatesFor(TrackMatchQuery track) {
    final title = normalizeMetadata(track.title);
    final exactTitleCandidates = byNormalizedTitle[title];
    if (exactTitleCandidates != null && exactTitleCandidates.isNotEmpty) {
      return exactTitleCandidates;
    }

    final expectedArtist = normalizeMetadata(track.artist);
    if (expectedArtist.isEmpty) return const <TrackMatchCandidate>[];

    final expectedArtistTokens = expectedArtist
        .split(' ')
        .where((token) => token.length > 1)
        .toSet();
    if (expectedArtistTokens.isEmpty) return const <TrackMatchCandidate>[];

    return all
        .where((candidate) {
          final candidateArtist = candidate.normalizedArtist;
          if (candidateArtist.isEmpty) return false;
          if (candidateArtist == expectedArtist) return true;
          if (candidateArtist.contains(expectedArtist) ||
              expectedArtist.contains(candidateArtist)) {
            return true;
          }
          final candidateArtistTokens = candidateArtist
              .split(' ')
              .where((token) => token.length > 1)
              .toSet();
          return expectedArtistTokens
              .intersection(candidateArtistTokens)
              .isNotEmpty;
        })
        .toList(growable: false);
  }
}

TrackMatchResult pickBestTrackMatch({
  required TrackMatchQuery track,
  required List<TrackMatchCandidate> candidates,
}) {
  final expectedTitle = normalizeMetadata(track.title);
  final expectedArtist = normalizeMetadata(track.artist);
  if (expectedTitle.isEmpty || expectedArtist.isEmpty || candidates.isEmpty) {
    return const TrackMatchResult.unmatched();
  }

  final expectedRecordingMbid = track.recordingMbid?.trim().toLowerCase();
  var candidatesToScore = candidates;
  if (expectedRecordingMbid != null && expectedRecordingMbid.isNotEmpty) {
    final mbidMatches = candidates
        .where(
          (candidate) =>
              candidate.recordingMbid?.trim().toLowerCase() ==
              expectedRecordingMbid,
        )
        .toList(growable: false);
    if (mbidMatches.length == 1) {
      return TrackMatchResult.matched(
        song: mbidMatches.single.song,
        tableSong: mbidMatches.single.tableSong,
      );
    }
    if (mbidMatches.length > 1) {
      candidatesToScore = mbidMatches;
    }
  }

  final scored =
      <({TrackMatchCandidate candidate, double score, double albumScore})>[];
  final expectedAlbum = normalizeMetadata(track.album ?? '');
  for (final candidate in candidatesToScore) {
    final candidateTitle = candidate.normalizedTitle;
    final candidateArtist = candidate.normalizedArtist;
    if (candidateTitle.isEmpty || candidateArtist.isEmpty) continue;

    final titleScore = trackMatchFieldScore(expectedTitle, candidateTitle);
    final artistScore = trackMatchFieldScore(expectedArtist, candidateArtist);
    if (titleScore < kLocalTrackMatcherMinimumFieldScore ||
        artistScore < kLocalTrackMatcherMinimumFieldScore) {
      continue;
    }

    var score = (titleScore * 0.58) + (artistScore * 0.32);
    var albumScore = 0.0;
    final candidateAlbum = candidate.normalizedAlbum;
    if (expectedAlbum.isNotEmpty && candidateAlbum.isNotEmpty) {
      albumScore = trackMatchFieldScore(expectedAlbum, candidateAlbum);
      score += albumScore * 0.06;
    }
    final expectedDuration = track.durationSeconds;
    final candidateDuration = candidate.song.duration;
    if (expectedDuration != null && candidateDuration != null) {
      final diff = (expectedDuration - candidateDuration).abs();
      if (diff <= 3) {
        score += 0.04;
      } else if (diff > 15) {
        score -= 0.08;
      }
    }
    scored.add((
      candidate: candidate,
      score: score.clamp(0.0, 1.0),
      albumScore: albumScore,
    ));
  }

  scored.sort((a, b) => b.score.compareTo(a.score));
  if (scored.isEmpty || scored.first.score < kLocalTrackMatcherMinimumScore) {
    return const TrackMatchResult.unmatched();
  }
  if (scored.length > 1 &&
      scored.first.score - scored[1].score < kLocalTrackMatcherAmbiguousDelta &&
      (scored.first.albumScore - scored[1].albumScore).abs() <
          kLocalTrackMatcherAmbiguousDelta &&
      scored.first.candidate.song.id != scored[1].candidate.song.id) {
    if (canChooseEquivalentTopTrackMatch(
      track: track,
      first: scored.first.candidate.song,
      second: scored[1].candidate.song,
    )) {
      return TrackMatchResult.matched(
        song: scored.first.candidate.song,
        tableSong: scored.first.candidate.tableSong,
      );
    }
    return const TrackMatchResult.ambiguous();
  }
  return TrackMatchResult.matched(
    song: scored.first.candidate.song,
    tableSong: scored.first.candidate.tableSong,
  );
}

double trackMatchFieldScore(String expected, String actual) {
  if (expected == actual) return 1.0;
  if (expected.replaceAll(' ', '') == actual.replaceAll(' ', '')) {
    return 0.98;
  }
  if (expected.contains(actual) || actual.contains(expected)) return 0.88;
  final expectedTokens = expected.split(' ').where((t) => t.isNotEmpty).toSet();
  final actualTokens = actual.split(' ').where((t) => t.isNotEmpty).toSet();
  if (expectedTokens.isEmpty || actualTokens.isEmpty) return 0.0;
  final overlap = expectedTokens.intersection(actualTokens).length;
  return overlap / math.max(expectedTokens.length, actualTokens.length);
}

bool canChooseEquivalentTopTrackMatch({
  required TrackMatchQuery track,
  required Song first,
  required Song second,
}) {
  final expectedTitle = normalizeMetadata(track.title);
  final expectedArtist = normalizeMetadata(track.artist);
  if (expectedTitle.isEmpty || expectedArtist.isEmpty) return false;

  final firstTitle = normalizeMetadata(first.title);
  final secondTitle = normalizeMetadata(second.title);
  final firstArtist = normalizeMetadata(first.artist ?? '');
  final secondArtist = normalizeMetadata(second.artist ?? '');
  if (firstTitle != expectedTitle ||
      secondTitle != expectedTitle ||
      firstArtist != expectedArtist ||
      secondArtist != expectedArtist) {
    return false;
  }

  final expectedAlbum = normalizeMetadata(track.album ?? '');
  if (expectedAlbum.isNotEmpty) {
    final firstAlbum = normalizeMetadata(first.album ?? '');
    final secondAlbum = normalizeMetadata(second.album ?? '');
    if (firstAlbum == expectedAlbum && secondAlbum != expectedAlbum) {
      return true;
    }
    if (secondAlbum == expectedAlbum && firstAlbum != expectedAlbum) {
      return false;
    }
  }

  final expectedDuration = track.durationSeconds;
  if (expectedDuration != null) {
    final firstDuration = first.duration;
    final secondDuration = second.duration;
    final firstDiff = firstDuration == null
        ? 1 << 20
        : (firstDuration - expectedDuration).abs();
    final secondDiff = secondDuration == null
        ? 1 << 20
        : (secondDuration - expectedDuration).abs();
    if ((firstDiff - secondDiff).abs() > 3) {
      return firstDiff < secondDiff;
    }
  }

  return true;
}
