/// A bounded, redacted timeline for one playback selection.
///
/// Song identity stays private to the handler so diagnostics can correlate
/// stages without retaining titles, URLs, or server credentials.
class PlaybackStartupTrace {
  new({
    required this.attempt,
    required this.songId,
    required this.isExternal,
    this.awaitingHandler = false,
  }) {
    _watch.start();
    mark('selection');
  }

  final int attempt;
  final String songId;
  final bool isExternal;
  bool awaitingHandler;
  final Stopwatch _watch = Stopwatch();
  final List<Map<String, Object>> _events = <Map<String, Object>>[];
  String? sourceKind;
  bool _firstPositionSeen = false;
  Duration? _lastObservedPosition;

  bool get sourceApplied =>
      _events.any((event) => event['stage'] == 'selectedSourceApplyComplete');

  void mark(String stage) {
    if (_events.length >= 32) {
      return;
    }
    _events.add(<String, Object>{
      'stage': stage,
      'elapsedMs': _watch.elapsedMilliseconds,
    });
  }

  void markOnce(String stage) {
    if (_events.any((event) => event['stage'] == stage)) {
      return;
    }
    mark(stage);
  }

  void observePosition(Duration position) {
    if (_firstPositionSeen) {
      return;
    }
    final previous = _lastObservedPosition;
    _lastObservedPosition = position;
    if (previous == null || position <= previous) {
      return;
    }
    _firstPositionSeen = true;
    mark('firstAdvancingPosition');
  }

  Map<String, Object?> toDiagnostics() => <String, Object?>{
    'attempt': attempt,
    'external': isExternal,
    'sourceKind': sourceKind,
    'events': <Map<String, Object>>[
      for (final event in _events) Map<String, Object>.from(event),
    ],
  };
}
