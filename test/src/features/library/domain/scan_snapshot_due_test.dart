import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';

final _now = DateTime.utc(2026, 11, 7, 12);

LibraryScanObservationTableData _observation({
  bool supported = true,
  bool pending = true,
  String? observed = 'T2',
  String? reconciled = 'T1',
}) => LibraryScanObservationTableData(
  serverId: 1,
  scanSupported: supported,
  observedToken: observed,
  reconciledToken: reconciled,
  pendingReconciliation: pending,
);

LibrarySyncWorkTableData _work(String status, Duration age) =>
    LibrarySyncWorkTableData(
      id: 1,
      serverId: 1,
      kind: 'catalogSnapshot',
      entityId: '',
      priority: 60,
      workClass: 'background',
      status: status,
      attemptCount: 0,
      createdAt: _now.subtract(const Duration(days: 30)),
      updatedAt: _now.subtract(age),
    );

bool _due(
  LibraryScanObservationTableData? observation,
  LibrarySyncWorkTableData? work, {
  bool manual = false,
}) => scanSnapshotDue(
  observation: observation,
  work: work,
  now: _now,
  manual: manual,
);

void main() {
  group('scanSnapshotDue', () {
    test('needs a supported, pending, unreconciled completed-scan token', () {
      expect(_due(null, null), isFalse);
      expect(_due(_observation(supported: false), null), isFalse);
      expect(_due(_observation(pending: false), null), isFalse);
      expect(
        _due(_observation(observed: 'T1', reconciled: 'T1'), null),
        isFalse,
      );
      expect(_due(_observation(observed: null), null), isFalse);
      expect(_due(_observation(observed: null), null, manual: true), isFalse);
      expect(_due(_observation(), null), isTrue);
      expect(_due(_observation(reconciled: null), null), isTrue);
    });

    test('a pending scan with no snapshot work row is due', () {
      expect(_due(_observation(), null), isTrue);
      expect(_due(_observation(), null, manual: true), isTrue);
    });

    test('queued and running snapshot work is left to selection', () {
      for (final status in ['queued', 'running']) {
        final work = _work(status, const Duration(days: 3));
        expect(_due(_observation(), work), isFalse, reason: status);
        expect(_due(_observation(), work, manual: true), isFalse);
      }
    });

    test('a failed snapshot keeps its backoff unless the user asks', () {
      final failed = _work('failed', const Duration(days: 3));
      expect(_due(_observation(), failed), isFalse);
      expect(_due(_observation(), failed, manual: true), isTrue);
    });

    test('automatic passes wait 24 h from the last attempt, manual never', () {
      for (final status in ['completed', 'cancelled', 'skipped']) {
        final recent = _work(status, const Duration(hours: 2));
        expect(_due(_observation(), recent), isFalse, reason: status);
        expect(_due(_observation(), recent, manual: true), isTrue);
        final tenMinutes = _work(status, const Duration(minutes: 10));
        expect(_due(_observation(), tenMinutes), isFalse);
        expect(_due(_observation(), tenMinutes, manual: true), isTrue);
        final old = _work(status, const Duration(hours: 25));
        expect(_due(_observation(), old), isTrue, reason: status);
      }
    });

    test('a snapshot awaiting confirmation is throttled like any attempt', () {
      final awaiting = _work('awaitingConfirmation', const Duration(hours: 2));
      expect(_due(_observation(), awaiting), isFalse);
    });
  });
}
