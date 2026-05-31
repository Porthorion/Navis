class GroupListeningServerClockEstimator {
  GroupListeningServerClockEstimator({
    this.windowSize = 8,
    this.maxRoundTripTime = const Duration(milliseconds: 1500),
  }) : assert(windowSize > 0, 'windowSize must be positive');

  final int windowSize;
  final Duration maxRoundTripTime;
  final List<Duration> _offsetSamples = <Duration>[];

  Duration _clockOffset = Duration.zero;
  Duration? _lastRoundTripTime;
  Duration? _lastSampleOffset;

  Duration get clockOffset => _clockOffset;
  Duration? get lastRoundTripTime => _lastRoundTripTime;
  Duration? get lastSampleOffset => _lastSampleOffset;
  int get sampleCount => _offsetSamples.length;

  bool recordSample({
    required DateTime clientSendTime,
    required DateTime serverReceiveTime,
    required DateTime serverSendTime,
    required DateTime clientReceiveTime,
  }) {
    final serverProcessingTime = serverSendTime.difference(serverReceiveTime);
    final roundTripTime =
        clientReceiveTime.difference(clientSendTime) - serverProcessingTime;
    if (roundTripTime.isNegative || roundTripTime > maxRoundTripTime) {
      return false;
    }

    final sampleOffset = Duration(
      milliseconds:
          (serverReceiveTime.difference(clientSendTime).inMilliseconds +
              serverSendTime.difference(clientReceiveTime).inMilliseconds) ~/
          2,
    );
    _recordOffset(sampleOffset);
    _lastRoundTripTime = roundTripTime;
    return true;
  }

  void recordInstantSample({
    required DateTime serverTime,
    required DateTime clientReceiveTime,
  }) {
    _recordOffset(serverTime.difference(clientReceiveTime.toUtc()));
    _lastRoundTripTime = Duration.zero;
  }

  DateTime toServerTime(DateTime localTime) {
    return localTime.toUtc().add(_clockOffset);
  }

  void clear() {
    _offsetSamples.clear();
    _clockOffset = Duration.zero;
    _lastRoundTripTime = null;
    _lastSampleOffset = null;
  }

  void _recordOffset(Duration sampleOffset) {
    _offsetSamples.add(sampleOffset);
    if (_offsetSamples.length > windowSize) {
      _offsetSamples.removeAt(0);
    }

    final sortedOffsets = List<Duration>.from(_offsetSamples)..sort();
    _clockOffset = sortedOffsets[sortedOffsets.length ~/ 2];
    _lastSampleOffset = sampleOffset;
  }
}
