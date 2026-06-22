import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/utils/song_id_utils.dart';

/// Scores search3 candidates against portable track fingerprints.
class GroupListeningTrackMatchScorer {
  const GroupListeningTrackMatchScorer({
    this.minimumScore = 0.62,
    this.durationToleranceSeconds = 2,
  });

  final double minimumScore;
  final int durationToleranceSeconds;

  Song? pickBestCandidate({
    required GroupListeningSearchFingerprint fingerprint,
    required List<Song> songs,
  }) {
    Song? best;
    var bestScore = 0.0;
    for (final candidate in songs) {
      final id = candidate.id.trim();
      if (id.isEmpty || !isServerAddressableSongId(id)) {
        continue;
      }
      final score = scoreCandidate(
        fingerprint: fingerprint,
        candidate: candidate,
      );
      if (score >= minimumScore && score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  double scoreCandidate({
    required GroupListeningSearchFingerprint fingerprint,
    required Song candidate,
  }) {
    final titleScore = _fuzzyScore(fingerprint.title, candidate.title);
    final artistScore = _fuzzyScore(fingerprint.artist, candidate.artist ?? '');
    final durationScore = _durationScore(
      fingerprint.durationSeconds,
      candidate.duration,
    );
    return (titleScore * 0.45) + (artistScore * 0.35) + (durationScore * 0.20);
  }

  double _fuzzyScore(String left, String right) {
    final a = left.trim().toLowerCase();
    final b = right.trim().toLowerCase();
    if (a.isEmpty || b.isEmpty) {
      return 0;
    }
    if (a == b) {
      return 1;
    }
    if (a.contains(b) || b.contains(a)) {
      return 0.85;
    }
    return 0;
  }

  double _durationScore(int expectedSeconds, int? actualSeconds) {
    if (expectedSeconds <= 0 || actualSeconds == null || actualSeconds <= 0) {
      return 0.5;
    }
    final delta = (expectedSeconds - actualSeconds).abs();
    if (delta <= durationToleranceSeconds) {
      return 1;
    }
    if (delta <= 10) {
      return 0.5;
    }
    return 0;
  }
}
