import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_server_clock_estimator.dart';

void main() {
  group('GroupListeningServerClockEstimator', () {
    test('records positive clock offset samples', () {
      final estimator = GroupListeningServerClockEstimator();

      final accepted = _recordOffsetSample(estimator, offsetMs: 250);

      expect(accepted, isTrue);
      expect(estimator.clockOffset, const Duration(milliseconds: 250));
      expect(estimator.lastRoundTripTime, const Duration(milliseconds: 100));
      expect(estimator.lastSampleOffset, const Duration(milliseconds: 250));
      expect(estimator.sampleCount, 1);
    });

    test('records negative clock offset samples', () {
      final estimator = GroupListeningServerClockEstimator();

      final accepted = _recordOffsetSample(estimator, offsetMs: -400);

      expect(accepted, isTrue);
      expect(estimator.clockOffset, const Duration(milliseconds: -400));
      expect(
        estimator.toServerTime(_baseClientSendTime),
        _baseClientSendTime.subtract(const Duration(milliseconds: 400)),
      );
    });

    test('uses a median offset over the sample window', () {
      final estimator = GroupListeningServerClockEstimator(windowSize: 3);

      _recordOffsetSample(estimator, offsetMs: 100);
      _recordOffsetSample(estimator, offsetMs: 900, sampleIndex: 1);
      _recordOffsetSample(estimator, offsetMs: 200, sampleIndex: 2);

      expect(estimator.clockOffset, const Duration(milliseconds: 200));

      _recordOffsetSample(estimator, offsetMs: 300, sampleIndex: 3);

      expect(estimator.sampleCount, 3);
      expect(estimator.clockOffset, const Duration(milliseconds: 300));
    });

    test('seeds offset from an instant server time sample', () {
      final estimator = GroupListeningServerClockEstimator();
      final clientReceiveTime = _baseClientSendTime.add(
        const Duration(milliseconds: 250),
      );

      estimator.recordInstantSample(
        serverTime: _baseClientSendTime,
        clientReceiveTime: clientReceiveTime,
      );

      expect(estimator.clockOffset, const Duration(milliseconds: -250));
      expect(estimator.lastRoundTripTime, Duration.zero);
      expect(estimator.sampleCount, 1);
    });

    test('rejects negative and excessive round trip samples', () {
      final estimator = GroupListeningServerClockEstimator(
        maxRoundTripTime: const Duration(milliseconds: 1500),
      );

      final excessive = estimator.recordSample(
        clientSendTime: _baseClientSendTime,
        serverReceiveTime: _baseClientSendTime.add(
          const Duration(milliseconds: 50),
        ),
        serverSendTime: _baseClientSendTime.add(
          const Duration(milliseconds: 60),
        ),
        clientReceiveTime: _baseClientSendTime.add(
          const Duration(milliseconds: 1700),
        ),
      );
      final negative = estimator.recordSample(
        clientSendTime: _baseClientSendTime,
        serverReceiveTime: _baseClientSendTime.add(
          const Duration(milliseconds: 10),
        ),
        serverSendTime: _baseClientSendTime.add(
          const Duration(milliseconds: 500),
        ),
        clientReceiveTime: _baseClientSendTime.add(
          const Duration(milliseconds: 100),
        ),
      );

      expect(excessive, isFalse);
      expect(negative, isFalse);
      expect(estimator.clockOffset, Duration.zero);
      expect(estimator.sampleCount, 0);
    });

    test('clears accumulated samples', () {
      final estimator = GroupListeningServerClockEstimator();
      _recordOffsetSample(estimator, offsetMs: 250);

      estimator.clear();

      expect(estimator.clockOffset, Duration.zero);
      expect(estimator.lastRoundTripTime, isNull);
      expect(estimator.lastSampleOffset, isNull);
      expect(estimator.sampleCount, 0);
    });
  });
}

final DateTime _baseClientSendTime = DateTime.utc(2026, 4, 21, 12);

bool _recordOffsetSample(
  GroupListeningServerClockEstimator estimator, {
  required int offsetMs,
  int sampleIndex = 0,
}) {
  final clientSendTime = _baseClientSendTime.add(
    Duration(seconds: sampleIndex),
  );
  const outboundLatency = Duration(milliseconds: 50);
  const serverProcessing = Duration(milliseconds: 10);
  const inboundLatency = Duration(milliseconds: 50);
  final clockOffset = Duration(milliseconds: offsetMs);
  return estimator.recordSample(
    clientSendTime: clientSendTime,
    serverReceiveTime: clientSendTime.add(outboundLatency).add(clockOffset),
    serverSendTime: clientSendTime
        .add(outboundLatency)
        .add(serverProcessing)
        .add(clockOffset),
    clientReceiveTime: clientSendTime
        .add(outboundLatency)
        .add(serverProcessing)
        .add(inboundLatency),
  );
}
