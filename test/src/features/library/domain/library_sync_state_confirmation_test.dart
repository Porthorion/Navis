import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

void main() {
  const held = LibrarySyncState(
    status: LibrarySyncStatus.partial,
    stage: LibrarySyncStage.validatingCandidate,
    candidateGeneration: 4,
    candidateStatus: 'awaitingDeletionConfirmation',
    deletionCandidateCount: 12,
  );

  test('copyWith carries and clears the deletion fingerprint', () {
    final withFingerprint = held.copyWith(deletionCandidateFingerprint: 'fp');
    expect(withFingerprint.deletionCandidateFingerprint, 'fp');
    // Unrelated copies keep it; an explicit clear drops it.
    expect(withFingerprint.copyWith().deletionCandidateFingerprint, 'fp');
    expect(
      withFingerprint
          .copyWith(clearDeletionCandidateFingerprint: true)
          .deletionCandidateFingerprint,
      isNull,
    );
  });

  test('heldDeletionConfirmation needs the whole hold and a server', () {
    final complete = held.copyWith(deletionCandidateFingerprint: 'fp');
    final confirmation = complete.heldDeletionConfirmation(3)!;
    expect(confirmation.serverId, 3);
    expect(confirmation.generation, 4);
    expect(confirmation.count, 12);
    expect(confirmation.fingerprint, 'fp');

    expect(complete.heldDeletionConfirmation(null), isNull);
    expect(held.heldDeletionConfirmation(3), isNull, reason: 'no fingerprint');
    expect(
      complete.copyWith(candidateStatus: 'ready').heldDeletionConfirmation(3),
      isNull,
    );
    expect(
      complete.copyWith(deletionCandidateCount: 0).heldDeletionConfirmation(3),
      isNull,
    );
  });
}
