enum BackfillPhase { idle, lyrics, artwork }

enum BackfillBlockedReason { none, offline, wifiOnly, rateLimited }

/// Counts of lyrics resolutions and newly stored covers in a run.
typedef BackfillResult = ({int lyricsResolved, int artworkStored});

/// Snapshot of the current pass, or its final counts while idle.
class BackfillProgress {
  const new({
    this.phase = BackfillPhase.idle,
    this.done = 0,
    this.total = 0,
    this.blockedReason = BackfillBlockedReason.none,
    this.lastResult = (lyricsResolved: 0, artworkStored: 0),
  });

  final BackfillPhase phase;
  final int done;
  final int total;
  final BackfillBlockedReason blockedReason;
  final BackfillResult lastResult;
}
