import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/settings/presentation/sync_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _FakeLibrarySyncController extends LibrarySyncController {
  _FakeLibrarySyncController({
    required this.stateValue,
    this.onSyncNow,
    this.onDiscardRepairCandidate,
  });

  final LibrarySyncState stateValue;
  final void Function({required bool allowMeteredBroadOverride})? onSyncNow;
  final Future<bool> Function()? onDiscardRepairCandidate;
  var repairCalls = 0;
  bool? lastRepairMeteredOverride;

  @override
  LibrarySyncState build() => stateValue;

  @override
  Future<LibrarySyncState> syncIfStale() async => stateValue;

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) async {
    onSyncNow?.call(allowMeteredBroadOverride: allowMeteredBroadOverride);
    return stateValue;
  }

  @override
  Future<LibrarySyncState> forceFullSync({
    bool allowMeteredBroadOverride = false,
  }) async => stateValue;

  @override
  Future<LibrarySyncState> syncUsingMobileData() {
    return syncNow(allowMeteredBroadOverride: true);
  }

  @override
  Future<bool> discardAwaitingRepairCandidate() async {
    return onDiscardRepairCandidate?.call() ?? false;
  }

  @override
  Future<LibrarySyncState> repairLibrary({
    bool allowMeteredBroadOverride = false,
  }) async {
    repairCalls++;
    lastRepairMeteredOverride = allowMeteredBroadOverride;
    return stateValue;
  }
}

void main() {
  testWidgets('shows the latest destructive library change from the ledger', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final database = createTestDatabase();
    addTearDown(database.close);
    final serverId = await database
        .into(database.serverConfigTable)
        .insert(
          ServerConfigTableCompanion.insert(
            url: 'https://example.com',
            username: 'alice',
            apiVersion: '1.16.1',
          ),
        );
    await database.librarySyncDao.recordOperationLedgerEntry(
      serverId: serverId,
      operation: 'catalogPromotion',
      reason: 'validatedFullCandidate',
      occurredAt: DateTime.utc(2026, 2, 20, 12),
      details: const <String, Object?>{
        'removed': <String, int>{'artists': 3, 'albums': 4, 'songs': 5},
      },
    );
    // A later no-op promotion must not hide the last operation that actually
    // changed the offline catalog.
    await database.librarySyncDao.recordOperationLedgerEntry(
      serverId: serverId,
      operation: 'catalogPromotion',
      reason: 'validatedFullCandidate',
      occurredAt: DateTime.utc(2026, 2, 20, 13),
      details: const <String, Object?>{
        'removed': <String, int>{'artists': 0, 'albums': 0, 'songs': 0},
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...withTestDatabase(database),
          serverConfigStateProvider.overrideWithValue(
            AsyncData(
              ServerConfigModel(
                id: serverId,
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(
              stateValue: LibrarySyncState.idle(),
            ),
          ),
          syncNetworkPolicyProvider.overrideWith(
            (_) => const SyncNetworkPolicy(
              networkType: NetworkType.wifi,
              isMetered: false,
              allowsBackgroundSync: true,
              allowsHardProbe: true,
              allowsInteractiveHydration: true,
            ),
          ),
          backgroundSyncUnmeteredOnlyProvider.overrideWith((_) => true),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SyncSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back to Settings'), findsOneWidget);
    expect(find.text('Last Library Change'), findsOneWidget);
    expect(
      find.text(
        'Catalog promotion removed 3 artist(s), 4 album(s), and 5 song(s).',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('humanizes legacy persisted resume reasons', (tester) async {
    final database = createTestDatabase();
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...withTestDatabase(database),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(
              stateValue: LibrarySyncState(
                status: LibrarySyncStatus.idle,
                stage: LibrarySyncStage.idle,
                planKind: LibrarySyncPlanKind.targetedHydration,
                planReason: 'resumetargetedHydration',
              ),
            ),
          ),
          syncNetworkPolicyProvider.overrideWith(
            (_) => const SyncNetworkPolicy(
              networkType: NetworkType.wifi,
              isMetered: false,
              allowsBackgroundSync: true,
              allowsHardProbe: true,
              allowsInteractiveHydration: true,
            ),
          ),
          backgroundSyncUnmeteredOnlyProvider.overrideWith((_) => true),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SyncSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Strategy: targeted hydration — resume targeted hydration'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('desktop summarizes sync state without exposing server errors', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final database = createTestDatabase();
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...withTestDatabase(database),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(
              stateValue: LibrarySyncState(
                status: LibrarySyncStatus.failed,
                stage: LibrarySyncStage.completed,
                errorMessage: 'HTTP 502 from a private server',
                planKind: LibrarySyncPlanKind.targetedHydration,
                planReason: 'resume targeted hydration',
                pendingWorkCount: 49,
                lastApplyDurationMs: 235,
                apiRequests: 2,
                lastRunBytes: 29696,
              ),
            ),
          ),
          syncNetworkPolicyProvider.overrideWith(
            (_) => const SyncNetworkPolicy(
              networkType: NetworkType.wifi,
              isMetered: false,
              allowsBackgroundSync: true,
              allowsHardProbe: true,
              allowsInteractiveHydration: true,
            ),
          ),
          backgroundSyncUnmeteredOnlyProvider.overrideWith((_) => true),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SyncSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not refresh your library. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('HTTP 502 from a private server'), findsNothing);
    expect(find.text('Sync Plan'), findsOneWidget);
    expect(find.text('Pending Work'), findsOneWidget);
    expect(find.text('Catalog Update'), findsOneWidget);
    expect(find.text('Last Run'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('phone retains the stacked sync-status reading order', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final database = createTestDatabase();
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...withTestDatabase(database),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(
              stateValue: LibrarySyncState(
                status: LibrarySyncStatus.idle,
                stage: LibrarySyncStage.idle,
                planKind: LibrarySyncPlanKind.targetedHydration,
                planReason: 'resume targeted hydration',
                pendingWorkCount: 49,
                lastApplyDurationMs: 235,
                apiRequests: 2,
                lastRunBytes: 29696,
              ),
            ),
          ),
          syncNetworkPolicyProvider.overrideWith(
            (_) => const SyncNetworkPolicy(
              networkType: NetworkType.wifi,
              isMetered: false,
              allowsBackgroundSync: true,
              allowsHardProbe: true,
              allowsInteractiveHydration: true,
            ),
          ),
          backgroundSyncUnmeteredOnlyProvider.overrideWith((_) => true),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SyncSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Strategy: targeted hydration — resume targeted hydration'),
      findsOneWidget,
    );
    expect(find.text('49 resumable task(s) pending'), findsOneWidget);
    expect(find.text('Catalog applied in 235 ms'), findsOneWidget);
    expect(find.text('Last run: 2 request(s) • 29.0 KB'), findsOneWidget);
    expect(find.text('Sync Plan'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('Repair Library enters the required full-screen rebuild flow', (
    tester,
  ) async {
    final lastSynced = DateTime(2026, 2, 20);
    final database = createTestDatabase();
    addTearDown(database.close);
    final router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => const SyncSettingsScreen(),
        ),
        GoRoute(
          path: '/library-rebuild',
          builder: (context, state) => const Scaffold(
            body: Text('Required library rebuild'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...withTestDatabase(database),
          serverConfigStateProvider.overrideWithValue(
            AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
                lastSynced: lastSynced,
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(
              stateValue: LibrarySyncState(
                status: LibrarySyncStatus.idle,
                stage: LibrarySyncStage.idle,
                lastSyncedAt: lastSynced,
                nextRetryAt: DateTime(2026, 2, 20, 12),
              ),
            ),
          ),
          syncNetworkPolicyProvider.overrideWith(
            (_) => const SyncNetworkPolicy(
              networkType: NetworkType.wifi,
              isMetered: false,
              allowsBackgroundSync: true,
              allowsHardProbe: true,
              allowsInteractiveHydration: true,
            ),
          ),
          backgroundSyncUnmeteredOnlyProvider.overrideWith((_) => true),
        ],
        child: MaterialApp.router(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sync Settings'), findsOneWidget);
    expect(find.text('Next Automatic Check'), findsOneWidget);
    expect(find.text('Scheduling…'), findsOneWidget);
    expect(find.text('Automatic Retry After Failure'), findsOneWidget);
    expect(find.text('Last Catalog Update'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(
      find.text('Background Sync Only on Unmetered Networks'),
      findsOneWidget,
    );
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Repair Library'), findsOneWidget);
    expect(
      find.text(
        'Reconcile your local library with the server. Keeps downloads, streaming cache, and artwork.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Repair Library'));
    await tester.pumpAndSettle();

    // Ordinary repair starts in place; the user is never forced onto the
    // blocking rebuild screen.
    expect(find.text('Required library rebuild'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/');
    final controller =
        ProviderScope.containerOf(
              tester.element(find.byType(SyncSettingsScreen)),
            ).read(librarySyncControllerProvider.notifier)
            as _FakeLibrarySyncController;
    expect(controller.repairCalls, 1);
    expect(controller.lastRepairMeteredOverride, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('shows redacted Android background schedule state', (
    tester,
  ) async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final serverId = await database
        .into(database.serverConfigTable)
        .insert(
          ServerConfigTableCompanion.insert(
            url: 'https://example.com',
            username: 'alice',
            apiVersion: '1.16.1',
          ),
        );
    await database.librarySyncDao.setAndroidBackgroundSyncEnabled(
      serverId: serverId,
      enabled: true,
    );
    await database.librarySyncDao.writeAndroidBackgroundStatus(
      serverId: serverId,
      requestedIntervalMinutes: 60,
      workState: 'blocked',
      workerCompletedAt: DateTime.utc(2026, 8, 12, 10),
      workerResult: 'deferredPolicy',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...withTestDatabase(database),
          serverConfigStateProvider.overrideWithValue(
            AsyncData(
              ServerConfigModel(
                id: serverId,
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(
              stateValue: LibrarySyncState.idle(),
            ),
          ),
          androidBackgroundSyncAvailableProvider.overrideWith((_) => true),
          syncNetworkPolicyProvider.overrideWith(
            (_) => const SyncNetworkPolicy(
              networkType: NetworkType.wifi,
              isMetered: false,
              allowsBackgroundSync: true,
              allowsHardProbe: true,
              allowsInteractiveHydration: true,
            ),
          ),
          backgroundSyncUnmeteredOnlyProvider.overrideWith((_) => true),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SyncSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Android Background Sync'), findsOneWidget);
    expect(
      find.textContaining('Requested cadence: every 60 minutes'),
      findsOneWidget,
    );
    expect(find.text('Waiting for an unmetered network.'), findsOneWidget);
    expect(find.text('Outcome: deferred policy'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('shows mobile data sync action when updates are deferred', (
    tester,
  ) async {
    var mobileSyncTriggered = false;
    final database = createTestDatabase();
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...withTestDatabase(database),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(
              stateValue: LibrarySyncState(
                status: LibrarySyncStatus.deferred,
                stage: LibrarySyncStage.completed,
                planKind: LibrarySyncPlanKind.deltaReconcile,
                updatesAvailable: true,
              ),
              onSyncNow: ({required allowMeteredBroadOverride}) {
                mobileSyncTriggered = true;
                expect(allowMeteredBroadOverride, isTrue);
              },
            ),
          ),
          syncNetworkPolicyProvider.overrideWith(
            (_) => const SyncNetworkPolicy(
              networkType: NetworkType.cellular,
              isMetered: true,
              allowsBackgroundSync: false,
              allowsHardProbe: true,
              allowsInteractiveHydration: true,
            ),
          ),
          backgroundSyncUnmeteredOnlyProvider.overrideWith((_) => true),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SyncSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Library updates are available'),
      findsOneWidget,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('Sync using mobile data'), findsOneWidget);

    await tester.tap(find.text('Sync using mobile data'));
    await tester.pumpAndSettle();

    expect(mobileSyncTriggered, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('repair on metered network requires confirmation', (
    tester,
  ) async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => const SyncSettingsScreen(),
        ),
        GoRoute(
          path: '/library-rebuild',
          builder: (context, state) => const Scaffold(
            body: Text('Required library rebuild'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...withTestDatabase(database),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(
              stateValue: LibrarySyncState.idle(),
            ),
          ),
          syncNetworkPolicyProvider.overrideWith(
            (_) => const SyncNetworkPolicy(
              networkType: NetworkType.cellular,
              isMetered: true,
              allowsBackgroundSync: false,
              allowsHardProbe: true,
              allowsInteractiveHydration: true,
            ),
          ),
          backgroundSyncUnmeteredOnlyProvider.overrideWith((_) => true),
        ],
        child: MaterialApp.router(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Repair Library'));
    await tester.pumpAndSettle();
    expect(
      find.text('Repair Library on Mobile Data?'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/');

    await tester.tap(find.text('Repair Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair on Mobile Data'));
    await tester.pumpAndSettle();
    expect(find.text('Required library rebuild'), findsNothing);
    final controller =
        ProviderScope.containerOf(
              tester.element(find.byType(SyncSettingsScreen)),
            ).read(librarySyncControllerProvider.notifier)
            as _FakeLibrarySyncController;
    expect(controller.repairCalls, 1);
    expect(controller.lastRepairMeteredOverride, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('repair requires confirmation before applying server deletions', (
    tester,
  ) async {
    var candidateDiscarded = false;
    final database = createTestDatabase();
    addTearDown(database.close);
    final router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => const SyncSettingsScreen(),
        ),
        GoRoute(
          path: '/library-rebuild',
          builder: (context, state) => const Scaffold(
            body: Text('Required library rebuild'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...withTestDatabase(database),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(
              stateValue: LibrarySyncState(
                status: LibrarySyncStatus.partial,
                stage: LibrarySyncStage.validatingCandidate,
                candidateGeneration: 12,
                candidateStatus: 'awaitingDeletionConfirmation',
                deletionCandidateCount: 531,
              ),
              onDiscardRepairCandidate: () async {
                candidateDiscarded = true;
                return true;
              },
            ),
          ),
          syncNetworkPolicyProvider.overrideWith(
            (_) => const SyncNetworkPolicy(
              networkType: NetworkType.wifi,
              isMetered: false,
              allowsBackgroundSync: true,
              allowsHardProbe: true,
              allowsInteractiveHydration: true,
            ),
          ),
          backgroundSyncUnmeteredOnlyProvider.overrideWith((_) => true),
        ],
        child: MaterialApp.router(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('531 server-missing item(s) are waiting'),
      findsOneWidget,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('Discard Repair Candidate'), findsOneWidget);
    await tester.tap(find.text('Discard Repair Candidate'));
    await tester.pumpAndSettle();
    expect(find.text('Discard Pending Library Repair?'), findsOneWidget);
    expect(candidateDiscarded, isFalse);
    await tester.tap(find.text('Discard Repair Candidate').last);
    await tester.pumpAndSettle();
    expect(candidateDiscarded, isTrue);

    await tester.tap(find.text('Repair Library'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm Library Repair'), findsOneWidget);
    expect(
      find.textContaining('server no longer reports 531 item(s)'),
      findsOneWidget,
    );
    expect(router.routeInformationProvider.value.uri.path, '/');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/');

    await tester.tap(find.text('Repair Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply Library Repair'));
    await tester.pumpAndSettle();
    expect(find.text('Required library rebuild'), findsNothing);
    final controller =
        ProviderScope.containerOf(
              tester.element(find.byType(SyncSettingsScreen)),
            ).read(librarySyncControllerProvider.notifier)
            as _FakeLibrarySyncController;
    expect(controller.repairCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
