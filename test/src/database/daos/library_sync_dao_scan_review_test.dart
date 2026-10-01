import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  setUp(() async {
    database = createTestDatabase();
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://example.test',
        username: 'fixture',
        apiVersion: '1.16.1',
      ),
    );
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'first completed-scan observation opens pending reconciliation',
    () async {
      await database.librarySyncDao.recordScanObservation(
        serverId: 1,
        scanInProgress: false,
        supported: true,
        providerScanToken: '2026-09-01T10:00:00.000Z',
      );

      final observation = await database.librarySyncDao.getScanObservation(1);
      expect(observation, isNotNull);
      expect(observation!.scanSupported, isTrue);
      expect(observation.observedToken, '2026-09-01T10:00:00.000Z');
      expect(observation.pendingReconciliation, isTrue);
      expect(observation.reconciledToken, isNull);
    },
    skip: !sqliteAvailable,
  );

  test('repeated observations of the same token coalesce', () async {
    await database.librarySyncDao.recordScanObservation(
      serverId: 1,
      scanInProgress: false,
      supported: true,
      providerScanToken: 'token-a',
    );
    await database.librarySyncDao.recordScanObservation(
      serverId: 1,
      scanInProgress: false,
      supported: true,
      providerScanToken: 'token-a',
    );

    final observation = await database.librarySyncDao.getScanObservation(1);
    expect(observation!.observedToken, 'token-a');
    expect(observation.observedAt, isNotNull);
  }, skip: !sqliteAvailable);

  test('in-progress scans never produce a token', () async {
    await database.librarySyncDao.recordScanObservation(
      serverId: 1,
      scanInProgress: true,
      supported: true,
      providerScanToken: 'ignored',
    );

    expect(await database.librarySyncDao.getScanObservation(1), isNull);
  }, skip: !sqliteAvailable);

  test('unsupported servers are recorded once without blocking', () async {
    await database.librarySyncDao.recordScanObservation(
      serverId: 1,
      scanInProgress: false,
      supported: false,
    );
    await database.librarySyncDao.recordScanObservation(
      serverId: 1,
      scanInProgress: false,
      supported: false,
    );

    final observation = await database.librarySyncDao.getScanObservation(1);
    expect(observation, isNotNull);
    expect(observation!.scanSupported, isFalse);
    expect(observation.observedToken, isNull);
    expect(observation.pendingReconciliation, isFalse);
  }, skip: !sqliteAvailable);

  test('markScanReconciled closes the pending window for the token', () async {
    await database.librarySyncDao.recordScanObservation(
      serverId: 1,
      scanInProgress: false,
      supported: true,
      providerScanToken: 'token-a',
    );
    await database.librarySyncDao.markScanReconciled(
      serverId: 1,
      token: 'token-a',
    );

    final reconciled = await database.librarySyncDao.getScanObservation(1);
    expect(reconciled!.pendingReconciliation, isFalse);
    expect(reconciled.reconciledToken, 'token-a');
    expect(reconciled.reconciledAt, isNotNull);

    // A later scan reopens the window.
    await database.librarySyncDao.recordScanObservation(
      serverId: 1,
      scanInProgress: false,
      supported: true,
      providerScanToken: 'token-b',
    );
    final reopened = await database.librarySyncDao.getScanObservation(1);
    expect(reopened!.pendingReconciliation, isTrue);
    expect(reopened.observedToken, 'token-b');
  }, skip: !sqliteAvailable);

  test('review entries refresh in place but keep user dispositions', () async {
    await database.librarySyncDao.recordRecoveryReview(
      serverId: 1,
      entityType: 'song',
      oldId: 'missing-1',
      savedTitle: 'Gone Song',
      savedSubtitle: 'Artist',
      reason: 'missingFromCatalog',
      evidenceGeneration: 12,
    );
    await database.librarySyncDao.recordRecoveryReview(
      serverId: 1,
      entityType: 'song',
      oldId: 'missing-1',
      savedTitle: 'Gone Song',
      reason: 'missingFromCatalog',
      evidenceGeneration: 13,
    );

    var pending = await database.librarySyncDao.getPendingRecoveryReview(1);
    expect(pending, hasLength(1));
    expect(pending.single.evidenceGeneration, 13);

    await database.librarySyncDao.setRecoveryReviewDisposition(
      id: pending.single.id,
      disposition: 'keptForLater',
    );
    // Sync evidence must not resurrect a reviewed row.
    await database.librarySyncDao.recordRecoveryReview(
      serverId: 1,
      entityType: 'song',
      oldId: 'missing-1',
      reason: 'missingFromCatalog',
      evidenceGeneration: 14,
    );
    pending = await database.librarySyncDao.getPendingRecoveryReview(1);
    expect(pending, isEmpty);
  }, skip: !sqliteAvailable);

  test('batch review inserts new rows and preserves reviewed rows', () async {
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(id: 'missing-1', title: 'First'),
      SongsTableCompanion.insert(id: 'missing-2', title: 'Second'),
    ]);
    final songs = [
      (await database.libraryDao.getSongById('missing-1'))!,
      (await database.libraryDao.getSongById('missing-2'))!,
    ];
    await database.librarySyncDao.recordRecoveryReview(
      serverId: 1,
      entityType: 'song',
      oldId: 'missing-2',
      savedTitle: 'Earlier title',
      reason: 'missingFromCatalog',
      evidenceGeneration: 11,
    );
    final reviewed = (await database.librarySyncDao.getPendingRecoveryReview(1))
        .single;
    await database.librarySyncDao.setRecoveryReviewDisposition(
      id: reviewed.id,
      disposition: 'keptForLater',
    );

    for (var attempt = 0; attempt < 2; attempt++) {
      await database.librarySyncDao.recordRecoveryReviewBatch(
        serverId: 1,
        retainedSongs: songs,
        evidenceGeneration: 12,
      );
    }

    final rows = await database
        .select(database.libraryRecoveryReviewTable)
        .get();
    expect(rows, hasLength(2));
    final newReview = rows.singleWhere((row) => row.oldId == 'missing-1');
    expect(newReview.disposition, 'pending');
    expect(newReview.evidenceGeneration, 12);
    final keptReview = rows.singleWhere((row) => row.oldId == 'missing-2');
    expect(keptReview.disposition, 'keptForLater');
    expect(keptReview.savedTitle, 'Earlier title');
    expect(keptReview.evidenceGeneration, 11);
  }, skip: !sqliteAvailable);
}
