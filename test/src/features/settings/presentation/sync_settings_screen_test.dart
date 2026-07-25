import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/settings/presentation/sync_settings_screen.dart';

import '../../../../helpers/test_theme.dart';

class _FakeLibrarySyncController extends LibrarySyncController {
  _FakeLibrarySyncController({
    required this.stateValue,
    this.onSyncNow,
  });

  final LibrarySyncState stateValue;
  final void Function({required bool forceFull})? onSyncNow;

  @override
  LibrarySyncState build() => stateValue;

  @override
  Future<LibrarySyncState> syncIfStale() async => stateValue;

  @override
  Future<LibrarySyncState> syncNow() async {
    onSyncNow?.call(forceFull: false);
    return stateValue;
  }

  @override
  Future<LibrarySyncState> forceFullSync() async {
    onSyncNow?.call(forceFull: true);
    return stateValue;
  }
}

void main() {
  testWidgets('renders last synced and triggers force full sync', (
    tester,
  ) async {
    var forceFullTriggered = false;
    final lastSynced = DateTime(2026, 2, 20);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
              onSyncNow: ({required forceFull}) {
                forceFullTriggered = forceFull;
              },
            ),
          ),
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
    expect(find.text('Server last synced'), findsOneWidget);
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Force Full Sync'), findsOneWidget);

    await tester.tap(find.text('Force Full Sync'));
    await tester.pumpAndSettle();

    expect(forceFullTriggered, isTrue);
  });
}
