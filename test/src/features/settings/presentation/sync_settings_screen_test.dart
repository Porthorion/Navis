import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
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
    this.onForceFullSync,
  });

  final LibrarySyncState stateValue;
  final void Function({required bool allowMeteredBroadOverride})? onSyncNow;
  final void Function({required bool allowMeteredBroadOverride})?
  onForceFullSync;

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
  }) async {
    onForceFullSync?.call(allowMeteredBroadOverride: allowMeteredBroadOverride);
    return stateValue;
  }

  @override
  Future<LibrarySyncState> syncUsingMobileData() {
    return syncNow(allowMeteredBroadOverride: true);
  }
}

void main() {
  testWidgets('renders last synced and triggers force full sync', (
    tester,
  ) async {
    var forceFullTriggered = false;
    final lastSynced = DateTime(2026, 2, 20);
    final database = createTestDatabase();
    addTearDown(database.close);

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
              stateValue: LibrarySyncState.idle(lastSyncedAt: lastSynced),
              onForceFullSync: ({required allowMeteredBroadOverride}) {
                forceFullTriggered = true;
                expect(allowMeteredBroadOverride, isFalse);
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
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SyncSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sync Settings'), findsOneWidget);
    expect(find.text('Last catalog update'), findsOneWidget);
    expect(
      find.text('Background sync only on unmetered networks'),
      findsOneWidget,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Repair Library Metadata'), findsOneWidget);
    expect(
      find.text(
        'Rebuild and reconcile library metadata. Keeps downloads, streaming cache, and artwork.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Repair Library Metadata'));
    await tester.pumpAndSettle();

    expect(forceFullTriggered, isTrue);

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
    bool? allowOverride;
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
              stateValue: LibrarySyncState.idle(),
              onForceFullSync: ({required allowMeteredBroadOverride}) {
                allowOverride = allowMeteredBroadOverride;
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
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Repair Library Metadata'));
    await tester.pumpAndSettle();
    expect(
      find.text('Repair library metadata on mobile data?'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(allowOverride, isNull);

    await tester.tap(find.text('Repair Library Metadata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair on mobile data'));
    await tester.pumpAndSettle();
    expect(allowOverride, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
