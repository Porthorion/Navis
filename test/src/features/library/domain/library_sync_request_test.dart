import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';

void main() {
  test('retains persisted origin, intent and safe-reason indices', () {
    expect(SyncRunOrigin.values.map((origin) => origin.name), [
      'libraryPullToRefresh',
      'settingsRepair',
      'cacheReset',
      'homeRefresh',
      'desktopCommand',
      'startup',
      'timer',
      'resume',
      'reconnect',
      'interaction',
      'androidWorker',
      'migration',
      'invariant',
      'legacyRecovery',
    ]);
    expect(SyncRunIntent.values.map((intent) => intent.name), [
      'automaticCatalogCheck',
      'manualCatalogCheck',
      'repairLibrary',
      'targetHydration',
      'auxiliaryRefresh',
    ]);
    expect(SyncSafeReason.values.map((reason) => reason.name), [
      'none',
      'offline',
      'meteredPolicy',
      'activePlayback',
      'backgrounded',
      'cooldown',
      'leaseHeld',
      'cancellation',
      'confirmationRequired',
      'networkFailure',
      'authenticationFailure',
      'responseBudgetExceeded',
      'providerUnsupported',
      'legacyAmbiguous',
      'unknownFailure',
    ]);
  });

  test('retains durable work names', () {
    expect(LibrarySyncPlanKind.values.map((kind) => kind.name), [
      'probe',
      'targetedHydration',
      'deltaReconcile',
      'catalogSnapshot',
      'compatibilityAudit',
      'fullRepair',
    ]);
  });

  test('automatic and explicit catalog requests retain priority and keys', () {
    const automatic = LibrarySyncRequest.automatic();
    const manual = LibrarySyncRequest.checkForUpdates();
    expect(automatic.priority, 20);
    expect(automatic.isAutomatic, isTrue);
    expect(automatic.isInteraction, isFalse);
    expect(automatic.canProbeCircuitEarly, isFalse);
    expect(automatic.coalescingKey, 'automaticCatalogCheck:catalog::none:');
    expect(manual.priority, 60);
    expect(manual.isAutomatic, isFalse);
    expect(manual.canProbeCircuitEarly, isTrue);
    expect(
      manual.coalescingKey,
      'manualCatalogCheck:catalog::boundedMeteredDiscovery:',
    );
  });

  test('repair and cache reset retain separate origins and identities', () {
    const repair = LibrarySyncRequest(
      origin: SyncRunOrigin.settingsRepair,
      intent: SyncRunIntent.repairLibrary,
    );
    const reset = LibrarySyncRequest.cacheReset();
    expect(repair.priority, 80);
    expect(reset.priority, 80);
    expect(repair.runHistoryIntent, SyncRunIntent.repairLibrary);
    expect(reset.runHistoryIntent, SyncRunIntent.repairLibrary);
    expect(repair.canProbeCircuitEarly, isTrue);
    expect(reset.canProbeCircuitEarly, isTrue);
    expect(repair.coalescingKey, 'repairLibrary:catalog::none:settingsRepair');
    expect(reset.coalescingKey, 'repairLibrary:catalog::none:cacheReset');
  });

  test('interactive target policy is independent of history intent', () {
    const request = LibrarySyncRequest(
      origin: SyncRunOrigin.interaction,
      intent: SyncRunIntent.automaticCatalogCheck,
      target: LibrarySyncTarget.album('album'),
    );
    expect(request.isAutomatic, isTrue);
    expect(request.isInteraction, isTrue);
    expect(request.priority, 100);
    expect(request.canProbeCircuitEarly, isTrue);
    expect(request.runHistoryIntent, SyncRunIntent.targetHydration);
    expect(request.coalescingKey, 'targetHydration:album:album:none:');
  });

  test(
    'automatic auxiliary policy keeps auxiliary history and consent keys',
    () {
      const automatic = LibrarySyncRequest(
        origin: SyncRunOrigin.timer,
        intent: SyncRunIntent.automaticCatalogCheck,
        target: LibrarySyncTarget.starred(),
      );
      const explicit = LibrarySyncRequest(
        origin: SyncRunOrigin.libraryPullToRefresh,
        intent: SyncRunIntent.manualCatalogCheck,
        target: LibrarySyncTarget.starred(),
        grant: SyncNetworkGrant.broadMeteredOnce,
      );
      expect(automatic.isAutomatic, isTrue);
      expect(automatic.priority, 20);
      expect(automatic.runHistoryIntent, SyncRunIntent.auxiliaryRefresh);
      expect(automatic.coalescingKey, 'auxiliaryRefresh:starred::none:');
      expect(explicit.isAutomatic, isFalse);
      expect(explicit.priority, 60);
      expect(explicit.runHistoryIntent, SyncRunIntent.auxiliaryRefresh);
      expect(
        explicit.coalescingKey,
        'auxiliaryRefresh:starred::broadMeteredOnce:',
      );
    },
  );

  test('retained resume and reconnect origins can probe early', () {
    for (final origin in [SyncRunOrigin.resume, SyncRunOrigin.reconnect]) {
      final request = LibrarySyncRequest.automatic(origin: origin);
      expect(request.isAutomatic, isTrue);
      expect(request.priority, 20);
      expect(request.canProbeCircuitEarly, isTrue);
    }
    expect(
      const LibrarySyncRequest.automatic(origin: SyncRunOrigin.startup)
          .canProbeCircuitEarly,
      isFalse,
    );
  });
}
