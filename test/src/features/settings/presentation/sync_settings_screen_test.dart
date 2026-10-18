import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/models.dart';
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
import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import '../../../../helpers/test_theme.dart';

class _FakeLibrarySyncController extends LibrarySyncController {
  new({
    required this.stateValue,
    this.onSyncNow,
    this.onDiscardRepairCandidate,
  });

  final LibrarySyncState stateValue;
  final void Function({required bool allowMeteredBroadOverride})? onSyncNow;
  final Future<bool> Function()? onDiscardRepairCandidate;
  int repairCalls = 0;
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
    return await (onDiscardRepairCandidate?.call() ?? false);
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

const _wifiPolicy = SyncNetworkPolicy(
  networkType: NetworkType.wifi,
  isMetered: false,
  allowsBackgroundSync: true,
  allowsHardProbe: true,
  allowsInteractiveHydration: true,
);

const _meteredPolicy = SyncNetworkPolicy(
  networkType: NetworkType.cellular,
  isMetered: true,
  allowsBackgroundSync: false,
  allowsHardProbe: true,
  allowsInteractiveHydration: true,
);

const _defaultServer = ServerConfigModel(
  url: 'https://example.com',
  username: 'alice',
  password: 'secret',
  apiVersion: '1.16.1',
);

/// Pumps [SyncSettingsScreen] with the shared overrides and settles it.
///
/// Give either [state] (a controller that always reports it) or [controller]
/// for one with callbacks. A [router] hosts the screen inside GoRouter;
/// otherwise it is the plain home route.
Future<void> _pumpSyncSettings(
  WidgetTester tester,
  NavisDatabase database, {
  ServerConfigModel server = _defaultServer,
  LibrarySyncState? state,
  _FakeLibrarySyncController Function()? controller,
  SyncNetworkPolicy policy = _wifiPolicy,
  List<Override> extraOverrides = const <Override>[],
  GoRouter? router,
}) async {
  assert(
    (state == null) != (controller == null),
    'Pass exactly one of state or controller.',
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...withTestDatabase(database),
        serverConfigStateProvider.overrideWithValue(AsyncData(server)),
        librarySyncControllerProvider.overrideWith(
          controller ?? () => _FakeLibrarySyncController(stateValue: state!),
        ),
        ...extraOverrides,
        syncNetworkPolicyProvider.overrideWith((_) => policy),
        backgroundSyncUnmeteredOnlyProvider.overrideWith((_) => true),
      ],
      child: router == null
          ? MaterialApp(
              theme: testTheme(),
              localizationsDelegates: navisLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const SyncSettingsScreen(),
            )
          : MaterialApp.router(
              theme: testTheme(),
              localizationsDelegates: navisLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router,
            ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unchanged probe keeps current freshness and the server notice', (
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
    final repository = await seedSyncSession(database);
    const album = Album(id: 'incomplete', name: 'Incomplete', songCount: 2);
    final api = FakeLibrarySyncApi()
      ..fastPathPages[0] = [album]
      ..albumDetails[album.id] = album.copyWith(
        songs: [const Song(id: 'one', title: 'One', albumId: 'incomplete')],
      )
      ..indexes = Indexes(
        lastModified: FakeLibrarySyncApi.defaultIndexesCursor,
      );
    final engine = serialDriftEngine(
      api: api,
      database: database,
      repository: repository,
    );
    final first = await tester.runAsync(
      () => engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      ),
    );
    expect(first!.status, LibrarySyncStatus.succeeded);
    expect(first.onlyIncompleteAlbumDetails, isTrue);
    final probe = await tester.runAsync(engine.probeCatalog);
    await _pumpSyncSettings(
      tester,
      database,
      state: probe,
      server: (await repository.getActiveServer())!,
    );
    expect(find.textContaining(' • Current'), findsOneWidget);
    expect(find.textContaining('Verification Pending'), findsNothing);
    expect(
      find.textContaining('A server rescan usually fixes this.'),
      findsOneWidget,
    );
    expect(
      find.textContaining("1 album's track list couldn't be loaded"),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, skip: !sqliteAvailable);

  for (final dateSource in [
    'initial catalog',
    'server sync',
    'state sync',
    'catalog update',
  ]) {
    testWidgets('last catalog date uses $dateSource evidence', (tester) async {
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
      final initialDate = DateTime(2026, 2, 1, 12);
      final serverDate = DateTime(2026, 2, 2, 12);
      final stateDate = DateTime(2026, 2, 3, 12);
      final catalogDate = DateTime(2026, 2, 4, 12);
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          currentGeneration: const Value(1),
          initialCatalogUsableAt: Value(initialDate),
        ),
      );
      final expectedDate = switch (dateSource) {
        'catalog update' => catalogDate,
        'state sync' => stateDate,
        'server sync' => serverDate,
        _ => initialDate,
      };
      await _pumpSyncSettings(
        tester,
        database,
        server: _defaultServer.copyWith(
          id: serverId,
          lastSynced: dateSource == 'initial catalog' ? null : serverDate,
        ),
        state: LibrarySyncState(
          status: LibrarySyncStatus.idle,
          stage: LibrarySyncStage.idle,
          lastSyncedAt:
              dateSource == 'state sync' || dateSource == 'catalog update'
              ? stateDate
              : null,
          lastCatalogUpdatedAt: dateSource == 'catalog update'
              ? catalogDate
              : null,
        ),
      );
      final catalogTile = find.ancestor(
        of: find.text('Last Catalog Update'),
        matching: find.byType(ListTile),
      );
      final material = MaterialLocalizations.of(
        tester.element(find.byType(SyncSettingsScreen)),
      );
      expect(
        find.descendant(
          of: catalogTile,
          matching: find.textContaining(material.formatFullDate(expectedDate)),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: catalogTile,
          matching: find.textContaining('Never synced'),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  }

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

    await _pumpSyncSettings(
      tester,
      database,
      server: ServerConfigModel(
        id: serverId,
        url: 'https://example.com',
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
      ),
      state: LibrarySyncState.idle(),
    );

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('Last Library Change'), findsOneWidget);
    expect(
      find.text(
        'The last library update removed 3 artists, 4 albums and 5 songs.',
      ),
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

    await _pumpSyncSettings(
      tester,
      database,
      controller: () => _FakeLibrarySyncController(
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
    );

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

    await _pumpSyncSettings(
      tester,
      database,
      controller: () => _FakeLibrarySyncController(
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
    );

    expect(
      find.text('Strategy: targeted hydration — resume targeted hydration'),
      findsOneWidget,
    );
    expect(find.text('49 resumable tasks pending'), findsOneWidget);
    expect(find.text('Catalog applied in 235 ms'), findsOneWidget);
    expect(find.text('Last run: 2 requests • 29.0 KB'), findsOneWidget);
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
          builder: (context, state) =>
              const Scaffold(body: Text('Required library rebuild')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await _pumpSyncSettings(
      tester,
      database,
      server: ServerConfigModel(
        url: 'https://example.com',
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
        lastSynced: lastSynced,
      ),
      controller: () => _FakeLibrarySyncController(
        stateValue: LibrarySyncState(
          status: LibrarySyncStatus.idle,
          stage: LibrarySyncStage.idle,
          lastSyncedAt: lastSynced,
          nextRetryAt: DateTime(2026, 2, 20, 12),
        ),
      ),
      router: router,
    );

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
    expect(find.text('Sync Library Now'), findsOneWidget);
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

  testWidgets('shows sync deadlines in local time', (tester) async {
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
          builder: (context, state) =>
              const Scaffold(body: Text('Required library rebuild')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await _pumpSyncSettings(
      tester,
      database,
      server: ServerConfigModel(
        url: 'https://example.com',
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
        lastSynced: lastSynced,
      ),
      controller: () => _FakeLibrarySyncController(
        stateValue: LibrarySyncState(
          status: LibrarySyncStatus.idle,
          stage: LibrarySyncStage.idle,
          lastSyncedAt: lastSynced,
          nextAutomaticCheckAt: DateTime.utc(2026, 2, 20, 12),
        ),
      ),
      router: router,
    );

    final context = tester.element(find.byType(SyncSettingsScreen));
    final material = MaterialLocalizations.of(context);
    final local = DateTime.utc(2026, 2, 20, 12).toLocal();
    expect(
      find.text(
        '${material.formatFullDate(local)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}',
      ),
      findsOneWidget,
    );
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

    await _pumpSyncSettings(
      tester,
      database,
      server: ServerConfigModel(
        id: serverId,
        url: 'https://example.com',
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
      ),
      state: LibrarySyncState.idle(),
      extraOverrides: [
        androidBackgroundSyncAvailableProvider.overrideWith((_) => true),
      ],
    );

    expect(find.text('Android Background Sync'), findsOneWidget);
    expect(
      find.textContaining('Requested cadence: every 60 minutes'),
      findsOneWidget,
    );
    expect(find.text('Waiting for an unmetered network.'), findsOneWidget);
    expect(find.text('Outcome: deferred policy'), findsOneWidget);
    await database.librarySyncDao.writeAndroidBackgroundStatus(
      serverId: serverId,
      workerResult: 'deferredSetup',
    );
    await tester.pumpAndSettle();
    expect(find.text('Outcome: waiting for first setup'), findsOneWidget);
    await database.librarySyncDao.writeAndroidBackgroundStatus(
      serverId: serverId,
      workerResult: 'deferredPlayback',
    );
    await tester.pumpAndSettle();
    expect(find.text('Outcome: deferred playback'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('shows mobile data sync action when updates are deferred', (
    tester,
  ) async {
    var mobileSyncTriggered = false;
    final database = createTestDatabase();
    addTearDown(database.close);

    await _pumpSyncSettings(
      tester,
      database,
      controller: () => _FakeLibrarySyncController(
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
      policy: _meteredPolicy,
    );

    expect(
      find.textContaining('Library updates are available'),
      findsOneWidget,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('Sync Using Mobile Data'), findsOneWidget);

    await tester.tap(find.text('Sync Using Mobile Data'));
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
          builder: (context, state) =>
              const Scaffold(body: Text('Required library rebuild')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await _pumpSyncSettings(
      tester,
      database,
      state: LibrarySyncState.idle(),
      policy: _meteredPolicy,
      router: router,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Repair Library'));
    await tester.pumpAndSettle();
    expect(find.text('Repair Library on Mobile Data?'), findsOneWidget);

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
          builder: (context, state) =>
              const Scaffold(body: Text('Required library rebuild')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await _pumpSyncSettings(
      tester,
      database,
      controller: () => _FakeLibrarySyncController(
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
      router: router,
    );

    expect(
      find.textContaining('531 items the server no longer has are waiting'),
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
      find.textContaining('server no longer reports 531 items'),
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

  group('pending album details', () {
    const key = ValueKey<String>('sync-settings-pending-album-details');

    Future<void> pumpWithState(
      WidgetTester tester,
      LibrarySyncState state,
    ) async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await _pumpSyncSettings(tester, database, state: state);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      });
    }

    testWidgets('reports the idle hydration backlog', (tester) async {
      await pumpWithState(
        tester,
        LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          lastSyncedAt: DateTime(2026, 10, 7, 8),
          pendingHydrationCount: 3,
        ),
      );

      expect(find.byKey(key), findsOneWidget);
      expect(
        find.text(
          "3 albums' track lists haven't been fetched yet. They load when "
          'you open them or during upcoming checks.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('blames incomplete server details when they remain', (
      tester,
    ) async {
      await pumpWithState(
        tester,
        LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          lastSyncedAt: DateTime(2026, 10, 7, 8),
          pendingHydrationCount: 1,
          onlyIncompleteAlbumDetails: true,
        ),
      );

      expect(find.byKey(key), findsOneWidget);
      expect(
        find.textContaining('A server rescan usually fixes this.'),
        findsOneWidget,
      );
      expect(
        find.textContaining("1 album's track list couldn't be loaded"),
        findsOneWidget,
      );
    });

    testWidgets('stays hidden without a backlog', (tester) async {
      await pumpWithState(
        tester,
        LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          lastSyncedAt: DateTime(2026, 10, 7, 8),
          pendingHydrationCount: 0,
        ),
      );

      expect(find.byKey(key), findsNothing);
    });

    testWidgets('stays hidden while a sync runs', (tester) async {
      await pumpWithState(
        tester,
        const LibrarySyncState(
          status: LibrarySyncStatus.running,
          stage: LibrarySyncStage.fetchingSongs,
          pendingHydrationCount: 3,
        ),
      );

      expect(find.byKey(key), findsNothing);
    });
  });
}
