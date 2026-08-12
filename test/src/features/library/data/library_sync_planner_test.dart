import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/data/library_sync_planner.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/utils/connectivity.dart';

void main() {
  test('durable target keys distinguish entity types and preserve IDs', () {
    const sharedId = 'shared:id';
    final artist = LibrarySyncTarget.artist(sharedId);
    final album = LibrarySyncTarget.album(sharedId);
    final playlist = LibrarySyncTarget.playlist(sharedId);

    expect(
      <String>{
        librarySyncTargetWorkKey(artist),
        librarySyncTargetWorkKey(album),
        librarySyncTargetWorkKey(playlist),
      },
      hasLength(3),
    );
    expect(
      librarySyncTargetEntityIdFromWorkKey(
        LibrarySyncTargetKind.playlist,
        librarySyncTargetWorkKey(playlist),
      ),
      sharedId,
    );
    expect(
      librarySyncTargetEntityIdFromWorkKey(
        LibrarySyncTargetKind.album,
        'legacy-raw-id',
      ),
      'legacy-raw-id',
    );
  });

  const planner = LibrarySyncPlanner();

  LibrarySyncPlannerContext context({
    LibrarySyncRequest request = const LibrarySyncRequest.automatic(),
    NetworkType networkType = NetworkType.wifi,
    bool? restrictsBackgroundSync,
    bool baseline = true,
    bool due = true,
    int pendingHydration = 0,
    SyncCapabilityMode indexes = SyncCapabilityMode.reliable,
    bool? indexChanged,
    bool explainable = false,
    bool auxiliaryDue = false,
    bool auditDue = false,
    bool repairRequired = false,
    bool foreground = true,
    bool playing = false,
  }) {
    return LibrarySyncPlannerContext(
      request: request,
      networkType: networkType,
      restrictsBackgroundSync:
          restrictsBackgroundSync ?? networkType == NetworkType.cellular,
      hasAuthoritativeBaseline: baseline,
      isCatalogCheckDue: due,
      pendingHydrationCount: pendingHydration,
      pendingWorkCount: 0,
      indexesMode: indexes,
      indexChanged: indexChanged,
      changeIsExplainable: explainable,
      auxiliaryDue: auxiliaryDue,
      auditDue: auditDue,
      repairRequired: repairRequired,
      isForeground: foreground,
      hasActivePlayback: playing,
    );
  }

  test('initial state selects an authoritative catalog snapshot', () {
    final plan = planner.plan(context(baseline: false));
    expect(plan.kind, LibrarySyncPlanKind.catalogSnapshot);
    expect(plan.shouldExecute, isTrue);
  });

  test('interactive album request selects immediate targeted hydration', () {
    final plan = planner.plan(
      context(
        request: const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.album('album-1'),
        ),
        networkType: NetworkType.cellular,
      ),
    );
    expect(plan.kind, LibrarySyncPlanKind.targetedHydration);
    expect(plan.shouldExecute, isTrue);
  });

  test('automatic liked refresh is a no-op while auxiliary data is fresh', () {
    final plan = planner.plan(
      context(
        request: const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.automatic,
          target: LibrarySyncTarget.starred(),
        ),
      ),
    );
    expect(plan.kind, LibrarySyncPlanKind.targetedHydration);
    expect(plan.shouldExecute, isFalse);
    expect(plan.reason, 'starredFresh');
  });

  test('explicit playlist-header refresh bypasses auxiliary freshness', () {
    final plan = planner.plan(
      context(
        request: const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.playlistHeaders(),
        ),
      ),
    );
    expect(plan.kind, LibrarySyncPlanKind.targetedHydration);
    expect(plan.shouldExecute, isTrue);
  });

  test('offline interactive work is retained but deferred', () {
    final plan = planner.plan(
      context(
        request: const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.album('album-1'),
        ),
        networkType: NetworkType.offline,
      ),
    );
    expect(plan.kind, LibrarySyncPlanKind.targetedHydration);
    expect(plan.shouldExecute, isFalse);
    expect(plan.deferred, isTrue);
  });

  test('pending album work resumes without a broad catalog scan', () {
    final plan = planner.plan(context(pendingHydration: 4));
    expect(plan.kind, LibrarySyncPlanKind.targetedHydration);
  });

  test('unchanged fresh domains produce a true no-op', () {
    final plan = planner.plan(
      context(due: false, indexChanged: false),
    );
    expect(plan.kind, LibrarySyncPlanKind.probe);
    expect(plan.shouldExecute, isFalse);
  });

  test('manual check bypasses automatic freshness and runs discovery', () {
    final plan = planner.plan(
      context(
        request: const LibrarySyncRequest.checkForUpdates(),
        due: false,
        auxiliaryDue: false,
        auditDue: false,
      ),
    );

    expect(plan.kind, LibrarySyncPlanKind.deltaReconcile);
    expect(plan.shouldExecute, isTrue);
    expect(plan.reason, 'manualCatalogDiscovery');
  });

  test(
    'offline manual check retains bounded discovery for eligible resume',
    () {
      final plan = planner.plan(
        context(
          request: const LibrarySyncRequest.checkForUpdates(),
          networkType: NetworkType.offline,
          due: false,
        ),
      );

      expect(plan.kind, LibrarySyncPlanKind.deltaReconcile);
      expect(plan.shouldExecute, isFalse);
      expect(plan.deferred, isTrue);
      expect(plan.reason, 'manualCatalogDiscoveryOffline');
    },
  );

  test('explainable index change selects bounded delta reconciliation', () {
    final plan = planner.plan(
      context(indexChanged: true, explainable: true),
    );
    expect(plan.kind, LibrarySyncPlanKind.deltaReconcile);
  });

  test('unexplained or regressing change selects a catalog snapshot', () {
    final plan = planner.plan(
      context(indexChanged: true, explainable: false),
    );
    expect(plan.kind, LibrarySyncPlanKind.catalogSnapshot);
  });

  test('unsupported indexes select only a due compatibility partition', () {
    final plan = planner.plan(
      context(
        indexes: SyncCapabilityMode.unsupported,
        auditDue: true,
      ),
    );
    expect(plan.kind, LibrarySyncPlanKind.compatibilityAudit);
  });

  test('reliable indexes select a due weekly rotating partition', () {
    final plan = planner.plan(context(auditDue: true));
    expect(plan.kind, LibrarySyncPlanKind.compatibilityAudit);
    expect(plan.reason, 'weeklyRotatingVerification');
  });

  test('automatic cellular work is limited to a cheap probe', () {
    final plan = planner.plan(context(networkType: NetworkType.cellular));
    expect(plan.kind, LibrarySyncPlanKind.probe);
    expect(plan.reason, 'cellularProbeOnly');
  });

  test('pending hydration cannot expand metered automatic sync', () {
    final plan = planner.plan(
      context(networkType: NetworkType.cellular, pendingHydration: 12),
    );
    expect(plan.kind, LibrarySyncPlanKind.probe);
    expect(plan.reason, 'cellularProbeOnly');
  });

  test('metered wifi follows the same automatic probe guard', () {
    final plan = planner.plan(
      context(
        networkType: NetworkType.wifi,
        restrictsBackgroundSync: true,
      ),
    );
    expect(plan.kind, LibrarySyncPlanKind.probe);
    expect(plan.reason, 'cellularProbeOnly');
  });

  test('repair override can execute broad work on metered networks', () {
    final plan = planner.plan(
      context(
        request: const LibrarySyncRequest.repair(
          allowMeteredBroadOverride: true,
        ),
        networkType: NetworkType.cellular,
      ),
    );
    expect(plan.kind, LibrarySyncPlanKind.fullRepair);
    expect(plan.deferred, isFalse);
    expect(plan.shouldExecute, isTrue);
  });

  test('broad cellular work is queued instead of enumerated', () {
    final plan = planner.plan(
      context(networkType: NetworkType.cellular, baseline: false),
    );
    expect(plan.kind, LibrarySyncPlanKind.catalogSnapshot);
    expect(plan.deferred, isTrue);
    expect(plan.shouldExecute, isFalse);
  });

  test('automatic repair waits for foreground idle unmetered safety', () {
    final plan = planner.plan(
      context(repairRequired: true, playing: true),
    );
    expect(plan.kind, LibrarySyncPlanKind.fullRepair);
    expect(plan.deferred, isTrue);
  });

  test('explicit repair remains guarded on cellular', () {
    final plan = planner.plan(
      context(
        request: const LibrarySyncRequest.repair(),
        networkType: NetworkType.cellular,
      ),
    );
    expect(plan.kind, LibrarySyncPlanKind.fullRepair);
    expect(plan.deferred, isTrue);
  });
}
