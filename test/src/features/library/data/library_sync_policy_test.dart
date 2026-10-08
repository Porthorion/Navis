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
          LibrarySyncIntent,
          LibrarySyncTrigger,
          LibrarySyncTargetKind,
          String,
        )
      >{
        'automaticProbe': (
          LibrarySyncPlanKind.probe,
          LibrarySyncIntent.automatic,
          LibrarySyncTrigger.interval,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'manualProbe': (
          LibrarySyncPlanKind.probe,
          LibrarySyncIntent.checkForUpdates,
          LibrarySyncTrigger.user,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'automaticDelta': (
          LibrarySyncPlanKind.deltaReconcile,
          LibrarySyncIntent.automatic,
          LibrarySyncTrigger.interval,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'manualDelta': (
          LibrarySyncPlanKind.deltaReconcile,
          LibrarySyncIntent.checkForUpdates,
          LibrarySyncTrigger.user,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        // The automatic caller restores this intent from the durable row.
        'queuedManualDelta': (
          LibrarySyncPlanKind.deltaReconcile,
          LibrarySyncIntent.checkForUpdates,
          LibrarySyncTrigger.user,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'snapshot': (
          LibrarySyncPlanKind.catalogSnapshot,
          LibrarySyncIntent.automatic,
          LibrarySyncTrigger.startup,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'audit': (
          LibrarySyncPlanKind.compatibilityAudit,
          LibrarySyncIntent.automatic,
          LibrarySyncTrigger.interval,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'repair': (
          LibrarySyncPlanKind.fullRepair,
          LibrarySyncIntent.repair,
          LibrarySyncTrigger.user,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'dormantAutomaticRepair': (
          LibrarySyncPlanKind.fullRepair,
          LibrarySyncIntent.automatic,
          LibrarySyncTrigger.reconnect,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'dormantManualRepair': (
          LibrarySyncPlanKind.fullRepair,
          LibrarySyncIntent.checkForUpdates,
          LibrarySyncTrigger.user,
          LibrarySyncTargetKind.catalog,
          'background',
        ),
        'auxiliary': (
          LibrarySyncPlanKind.targetedHydration,
          LibrarySyncIntent.automatic,
          LibrarySyncTrigger.interaction,
          LibrarySyncTargetKind.starred,
          'background',
        ),
        'explicitAuxiliary': (
          LibrarySyncPlanKind.targetedHydration,
          LibrarySyncIntent.checkForUpdates,
          LibrarySyncTrigger.user,
          LibrarySyncTargetKind.playlistHeaders,
          'background',
        ),
        'backlog': (
          LibrarySyncPlanKind.targetedHydration,
          LibrarySyncIntent.automatic,
          LibrarySyncTrigger.interval,
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
            LibrarySyncIntent.automatic,
            LibrarySyncTrigger.interaction,
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
      {...probe, ...interactive, 'manualDelta', 'queuedManualDelta'},
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
      {...probe, ...interactive, 'manualDelta', 'queuedManualDelta'},
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
        final (kind, intent, trigger, target, workClass) = entry.value;
        final policy = resolveSyncNetworkPolicy(
          networkType: network,
          nativeMetered: network == NetworkType.cellular,
          backgroundSyncUnmeteredOnly: true,
        );
        expect(
          librarySyncWorkAllowed(
            kind: kind,
            workClass: workClass,
            intent: intent,
            trigger: trigger,
            targetKind: target,
            policy: policy,
            isForeground: foreground,
            hasActivePlayback: playing,
            isBackgroundExecutor: worker,
            networkGrant: grant,
          ),
          allowed.contains(entry.key),
        );
      });
    }
  }
  test(
    'metered automation remains a hard probe when background sync is enabled',
    () {
      final policy = resolveSyncNetworkPolicy(
        networkType: NetworkType.cellular,
        nativeMetered: true,
        backgroundSyncUnmeteredOnly: false,
      );
      expect(
        librarySyncWorkAllowed(
          kind: LibrarySyncPlanKind.deltaReconcile,
          workClass: 'background',
          intent: LibrarySyncIntent.automatic,
          trigger: LibrarySyncTrigger.interval,
          policy: policy,
          isForeground: true,
          hasActivePlayback: false,
          isBackgroundExecutor: false,
          networkGrant: none,
        ),
        isFalse,
      );
    },
  );
}
