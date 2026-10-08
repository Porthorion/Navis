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

    expect(<String>{
      librarySyncTargetWorkKey(artist),
      librarySyncTargetWorkKey(album),
      librarySyncTargetWorkKey(playlist),
    }, hasLength(3));
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
    bool? allowsBackgroundSync,
    bool baseline = true,
    bool due = true,
    int pendingHydration = 0,
    SyncCapabilityMode indexes = SyncCapabilityMode.reliable,
    bool auxiliaryDue = false,
    bool auditDue = false,
    bool foreground = true,
    bool playing = false,
  }) {
    return LibrarySyncPlannerContext(
      request: request,
      networkPolicy: SyncNetworkPolicy(
        networkType: networkType,
        isMetered:
            restrictsBackgroundSync ?? networkType == NetworkType.cellular,
        allowsBackgroundSync:
            allowsBackgroundSync ??
            !(restrictsBackgroundSync ?? networkType == NetworkType.cellular),
        allowsHardProbe: networkType != NetworkType.offline,
        allowsInteractiveHydration: networkType != NetworkType.offline,
      ),
      hasAuthoritativeBaseline: baseline,
      isCatalogCheckDue: due,
      pendingHydrationCount: pendingHydration,
      pendingWorkCount: 0,
      indexesMode: indexes,
      auxiliaryDue: auxiliaryDue,
      auditDue: auditDue,
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
          intent: SyncRunIntent.manualCatalogCheck,
          target: LibrarySyncTarget.album('album-1'),
          origin: SyncRunOrigin.interaction,
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
          intent: SyncRunIntent.automaticCatalogCheck,
          target: LibrarySyncTarget.starred(),
          origin: SyncRunOrigin.interaction,
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
          intent: SyncRunIntent.manualCatalogCheck,
          target: LibrarySyncTarget.playlistHeaders(),
          origin: SyncRunOrigin.interaction,
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
          intent: SyncRunIntent.manualCatalogCheck,
          target: LibrarySyncTarget.album('album-1'),
          origin: SyncRunOrigin.interaction,
        ),
        networkType: NetworkType.offline,
      ),
    );
    expect(plan.kind, LibrarySyncPlanKind.targetedHydration);
    expect(plan.shouldExecute, isFalse);
    expect(plan.deferred, isTrue);
  });

  test('pending album work resumes without a broad catalog scan', () {
    final plan = planner.plan(context(pendingHydration: 4, due: false));
    expect(plan.kind, LibrarySyncPlanKind.targetedHydration);
  });

  test('unchanged fresh domains produce a true no-op', () {
    final plan = planner.plan(context(due: false));
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

  test('eligible due automatic checks discover beyond an unchanged index', () {
    final plan = planner.plan(context());
    expect(plan.kind, LibrarySyncPlanKind.deltaReconcile);
    expect(plan.reason, 'automaticCatalogDiscovery');
    expect(plan.shouldExecute, isTrue);
    final duringPlayback = planner.plan(context(playing: true));
    expect(duringPlayback.deferred, isTrue);
    final backgrounded = planner.plan(context(foreground: false));
    expect(backgrounded.deferred, isTrue);
  });

  test(
    'manual cellular check uses bounded discovery, not a probe or repair',
    () {
      final plan = planner.plan(
        context(
          request: const LibrarySyncRequest.checkForUpdates(),
          networkType: NetworkType.cellular,
          due: false,
        ),
      );

      expect(plan.kind, LibrarySyncPlanKind.deltaReconcile);
      expect(plan.shouldExecute, isTrue);
      expect(plan.reason, 'manualMeteredLimitedDiscovery');
    },
  );

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

  test('unsupported indexes select only a due compatibility partition', () {
    final plan = planner.plan(
      context(indexes: SyncCapabilityMode.unsupported, auditDue: true),
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
      context(networkType: NetworkType.wifi, restrictsBackgroundSync: true),
    );
    expect(plan.kind, LibrarySyncPlanKind.probe);
    expect(plan.reason, 'cellularProbeOnly');
  });

  for (final pending in [0, 4]) {
    test(
      'automatic mobile discovery respects enabled background sync: $pending',
      () {
        final allowed = context(
          networkType: NetworkType.cellular,
          allowsBackgroundSync: true,
          pendingHydration: pending,
        );
        final plan = planner.plan(allowed);
        expect(plan.kind, LibrarySyncPlanKind.deltaReconcile);
        expect(plan.shouldExecute, isTrue);
        expect(plan.deferred, isFalse);
        for (final (foreground, playing) in [(false, false), (true, true)]) {
          final blocked = planner.plan(
            context(
              networkType: NetworkType.cellular,
              allowsBackgroundSync: true,
              pendingHydration: pending,
              foreground: foreground,
              playing: playing,
            ),
          );
          expect(blocked.kind, LibrarySyncPlanKind.deltaReconcile);
          expect(blocked.shouldExecute, isFalse);
          expect(blocked.deferred, isTrue);
        }
      },
    );
  }

  for (final (grant, expected) in [
    (false, LibrarySyncPlanKind.probe),
    (true, LibrarySyncPlanKind.deltaReconcile),
  ]) {
    test('fresh automatic mobile planning with broad grant: $grant', () {
      final plan = planner.plan(
        context(
          request: LibrarySyncRequest(
            intent: SyncRunIntent.automaticCatalogCheck,
            origin: SyncRunOrigin.timer,
            grant: grant
                ? SyncNetworkGrant.broadMeteredOnce
                : SyncNetworkGrant.boundedMeteredDiscovery,
          ),
          networkType: NetworkType.cellular,
        ),
      );
      expect(plan.kind, expected);
      expect(plan.shouldExecute, isTrue);
    });
  }

  test('repair override can execute broad work on metered networks', () {
    final plan = planner.plan(
      context(
        request: const LibrarySyncRequest.repair(
          grant: SyncNetworkGrant.broadMeteredOnce,
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
