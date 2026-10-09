import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/utils/connectivity.dart';

void main() {
  const probe = {'automaticProbe', 'manualProbe'};
  const interactive = {'artist', 'album', 'playlist'};
  const explicit = {
    'manualDelta',
    'queuedManualDelta',
    'repair',
    'explicitAuxiliary',
  };
  const automaticBroad = {
    'automaticDelta',
    'snapshot',
    'audit',
    'auxiliary',
    'backlog',
  };
  const all = {...probe, ...interactive, ...explicit, ...automaticBroad};
  final work =
      <
        String,
        (
          LibrarySyncPlanKind,
          SyncRunIntent,
          SyncRunOrigin,
          LibrarySyncTargetKind,
          String,
        )
      >{
        'automaticProbe': (
          LibrarySyncPlanKind.probe,
          SyncRunIntent.automaticCatalogCheck,
          SyncRunOrigin.timer,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'manualProbe': (
          LibrarySyncPlanKind.probe,
          SyncRunIntent.manualCatalogCheck,
          SyncRunOrigin.libraryPullToRefresh,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'automaticDelta': (
          LibrarySyncPlanKind.deltaReconcile,
          SyncRunIntent.automaticCatalogCheck,
          SyncRunOrigin.timer,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'manualDelta': (
          LibrarySyncPlanKind.deltaReconcile,
          SyncRunIntent.manualCatalogCheck,
          SyncRunOrigin.libraryPullToRefresh,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        // The automatic caller restores this intent from the durable row.
        'queuedManualDelta': (
          LibrarySyncPlanKind.deltaReconcile,
          SyncRunIntent.manualCatalogCheck,
          SyncRunOrigin.libraryPullToRefresh,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'snapshot': (
          LibrarySyncPlanKind.catalogSnapshot,
          SyncRunIntent.automaticCatalogCheck,
          SyncRunOrigin.startup,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'audit': (
          LibrarySyncPlanKind.compatibilityAudit,
          SyncRunIntent.automaticCatalogCheck,
          SyncRunOrigin.timer,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'repair': (
          LibrarySyncPlanKind.fullRepair,
          SyncRunIntent.repairLibrary,
          SyncRunOrigin.libraryPullToRefresh,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'dormantAutomaticRepair': (
          LibrarySyncPlanKind.fullRepair,
          SyncRunIntent.automaticCatalogCheck,
          SyncRunOrigin.reconnect,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'dormantManualRepair': (
          LibrarySyncPlanKind.fullRepair,
          SyncRunIntent.manualCatalogCheck,
          SyncRunOrigin.libraryPullToRefresh,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'auxiliary': (
          LibrarySyncPlanKind.targetedHydration,
          SyncRunIntent.automaticCatalogCheck,
          SyncRunOrigin.interaction,
          LibrarySyncTargetKind.starred,
          'background',
        ),
        'explicitAuxiliary': (
          LibrarySyncPlanKind.targetedHydration,
          SyncRunIntent.manualCatalogCheck,
          SyncRunOrigin.libraryPullToRefresh,
          LibrarySyncTargetKind.playlistHeaders,
          'background',
        ),
        'backlog': (
          LibrarySyncPlanKind.targetedHydration,
          SyncRunIntent.automaticCatalogCheck,
          SyncRunOrigin.timer,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        for (final kind in [
          LibrarySyncTargetKind.artist,
          LibrarySyncTargetKind.album,
          LibrarySyncTargetKind.playlist,
        ])
          kind.name: (
            LibrarySyncPlanKind.targetedHydration,
            SyncRunIntent.automaticCatalogCheck,
            SyncRunOrigin.interaction,
            kind,
            'interactive',
          ),
      };
  const none = SyncNetworkGrant.none;
  const bounded = SyncNetworkGrant.boundedMeteredDiscovery;
  const broad = SyncNetworkGrant.broadMeteredOnce;
  for (final (name, network, foreground, playing, worker, grant, allowed) in [
    ('idle', NetworkType.wifi, true, false, false, none, all),
    (
      'playing',
      NetworkType.wifi,
      true,
      true,
      false,
      none,
      {...probe, ...interactive, ...explicit},
    ),
    (
      'hidden',
      NetworkType.wifi,
      false,
      false,
      false,
      none,
      {...probe, ...explicit},
    ),
    (
      'hidden while playing',
      NetworkType.wifi,
      false,
      true,
      false,
      broad,
      {...probe, ...explicit},
    ),
    ('worker', NetworkType.wifi, false, false, true, none, all),
    ('playing worker', NetworkType.wifi, false, true, true, none, probe),
    (
      'metered',
      NetworkType.cellular,
      true,
      false,
      false,
      none,
      {...probe, ...interactive},
    ),
    (
      'bounded metered',
      NetworkType.cellular,
      true,
      false,
      false,
      bounded,
      {
        ...probe,
        ...interactive,
        'automaticDelta',
        'manualDelta',
        'queuedManualDelta',
      },
    ),
    (
      'bounded metered playing',
      NetworkType.cellular,
      true,
      true,
      false,
      bounded,
      {...probe, ...interactive, 'manualDelta', 'queuedManualDelta'},
    ),
    (
      'bounded metered hidden',
      NetworkType.cellular,
      false,
      false,
      false,
      bounded,
      {...probe, 'manualDelta', 'queuedManualDelta'},
    ),
    ('broad metered', NetworkType.cellular, true, false, false, broad, all),
    (
      'broad metered playing',
      NetworkType.cellular,
      true,
      true,
      false,
      broad,
      {...probe, ...interactive, ...explicit},
    ),
    (
      'broad metered hidden',
      NetworkType.cellular,
      false,
      false,
      false,
      broad,
      {...probe, ...explicit},
    ),
    (
      'metered worker',
      NetworkType.cellular,
      false,
      false,
      true,
      none,
      {...probe, ...interactive},
    ),
    (
      'bounded metered worker',
      NetworkType.cellular,
      false,
      false,
      true,
      bounded,
      {
        ...probe,
        ...interactive,
        'automaticDelta',
        'manualDelta',
        'queuedManualDelta',
      },
    ),
    (
      'broad metered worker',
      NetworkType.cellular,
      false,
      false,
      true,
      broad,
      all,
    ),
    for (final grant in [none, bounded, broad])
      (
        'offline ${grant.name}',
        NetworkType.offline,
        true,
        false,
        false,
        grant,
        <String>{},
      ),
  ]) {
    for (final entry in work.entries) {
      test('$name: ${entry.key}', () {
        final (kind, intent, origin, target, workClass) = entry.value;
        final policy = resolveSyncNetworkPolicy(
          networkType: network,
          nativeMetered: network == NetworkType.cellular,
          backgroundSyncUnmeteredOnly: true,
        );
        expect(
          librarySyncWorkAllowed(
            kind: kind,
            workClass: workClass,
            request: LibrarySyncRequest(
              origin: origin,
              intent: intent,
              target: LibrarySyncTarget(target),
              grant: grant,
            ),
            policy: policy,
            isForeground: foreground,
            hasActivePlayback: playing,
            isBackgroundExecutor: worker,
          ),
          allowed.contains(entry.key),
        );
      });
    }
  }
  for (final network in [NetworkType.cellular, NetworkType.wifi]) {
    for (final (name, foreground, playing, worker, allowed) in [
      ('idle', true, false, false, all),
      ('playing', true, true, false, {...probe, ...interactive, ...explicit}),
      ('hidden', false, false, false, {...probe, ...explicit}),
      ('worker', false, false, true, all),
      ('playing worker', false, true, true, probe),
    ]) {
      for (final entry in work.entries) {
        test(
          'metered background enabled ${network.name} $name: ${entry.key}',
          () {
            final (kind, intent, origin, target, workClass) = entry.value;
            final policy = resolveSyncNetworkPolicy(
              networkType: network,
              nativeMetered: true,
              backgroundSyncUnmeteredOnly: false,
            );
            expect(policy.allowsBackgroundSync, isTrue);
            expect(
              librarySyncWorkAllowed(
                kind: kind,
                workClass: workClass,
                request: LibrarySyncRequest(
                  origin: origin,
                  intent: intent,
                  target: LibrarySyncTarget(target),
                  grant: none,
                ),
                policy: policy,
                isForeground: foreground,
                hasActivePlayback: playing,
                isBackgroundExecutor: worker,
              ),
              allowed.contains(entry.key),
            );
          },
        );
      }
    }
  }
}
