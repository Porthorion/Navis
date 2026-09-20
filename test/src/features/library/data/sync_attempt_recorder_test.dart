import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/sync_request_scope.dart';
import 'package:navis/src/features/library/data/sync_attempt_recorder.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

SyncRequestScope _scope() => SyncRequestScope(
  allowedEndpoints: {'getGenres'},
  maxRequests: 100,
  maxNewestPages: 1,
  maxAlbumHydrations: 1,
  maxResponseBytes: 10000,
  maxTotalBytes: 10000,
  maxConcurrency: 1,
  maxDuration: const Duration(minutes: 1),
  canRequest: () => true,
);

void main() {
  test(
    'coalesces checkpoints in the owner zone and bounds phase evidence',
    () async {
      final gate = Completer<void>();
      final writes = <Map<String, Object?>>[];
      final zones = <Object?>[];
      final key = Object();
      final recorder = runZoned(
        () => SyncAttemptRecorder(
          requestId: 1,
          attemptId: 2,
          scope: _scope(),
          checkpointInterval: const Duration(days: 1),
          write: (value) async {
            zones.add(Zone.current[key]);
            writes.add(value);
            if (writes.length == 1) await gate.future;
          },
        ),
        zoneValues: {key: 'owner'},
      );
      runZoned(() {
        for (var i = 0; i < 100; i++) {
          recorder.observe(
            LibrarySyncState(
              status: LibrarySyncStatus.running,
              stage: i.isEven
                  ? LibrarySyncStage.fetchingAlbums
                  : LibrarySyncStage.fetchingSongs,
              errorMessage: 'private payload',
              candidateStatus: 'private identifier',
            ),
          );
        }
      }, zoneValues: {key: 'nestedTransaction'});
      final finishing = recorder.finish(
        const LibrarySyncState(
          status: LibrarySyncStatus.partial,
          stage: LibrarySyncStage.completed,
          pendingHydrationCount: 4,
          remainingVerificationCount: 7,
        ),
      );
      gate.complete();
      await finishing;
      expect(writes.length, 2);
      expect(zones, ['owner', 'owner']);
      final last = writes.last;
      expect(last['captureComplete'], isTrue);
      expect(last['phases'], hasLength(32));
      expect(last['omittedPhases'], 70);
      expect(last['pending'], {
        'workRows': 0,
        'albumHydration': 4,
        'artistVerification': 7,
      });
      expect(jsonEncode(last), isNot(contains('private')));
    },
  );
  test(
    'an interrupted capture stays incomplete and reports checkpoint failure',
    () async {
      final writes = <Map<String, Object?>>[];
      var calls = 0;
      final recorder = SyncAttemptRecorder(
        requestId: 1,
        attemptId: 2,
        scope: _scope(),
        checkpointInterval: const Duration(days: 1),
        write: (value) async {
          if (calls++ == 0) throw StateError('unavailable');
          writes.add(value);
        },
      );
      recorder.observe(
        const LibrarySyncState(
          status: LibrarySyncStatus.running,
          stage: LibrarySyncStage.fetchingSongs,
        ),
      );
      await recorder.close();
      expect(writes.last['captureComplete'], isFalse);
      expect(writes.last['checkpointFailures'], 1);
      expect(writes.last['status'], 'running');
    },
  );
}
