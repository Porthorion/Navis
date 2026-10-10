import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:navis/src/features/settings/data/update_repository.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/update_pull_check.dart';
import 'package:navis/src/providers/app_providers.dart';

class _Sync extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) async => state;
}

class _Store extends UpdateCheckStore {
  final forces = <bool>[];

  @override
  Future<bool> shouldCheck({bool force = false}) async {
    forces.add(force);
    return force; // A prior check is still inside the throttle window.
  }
}

class _Repository extends UpdateRepository {
  new(this.store, this.result);
  final _Store store;
  final Completer<UpdateInfo?> result;

  @override
  Future<UpdateInfo?> checkForUpdate({
    String? updateChannel,
    bool forceCheck = false,
  }) async {
    if (!await store.shouldCheck(force: forceCheck)) return null;
    return await result.future;
  }
}

const _update = UpdateInfo(
  tagName: 'v1.5.1',
  htmlUrl: 'https://navis.porthorion.com/releases/v1.5.1',
  delivery: UpdateDelivery.selfUpdate,
  sha256: null,
  size: null,
);

void main() {
  for (final outcome in ['update', 'none', 'error', 'disposed']) {
    testWidgets(
      'Library pull resolves $outcome without waiting for the check',
      (tester) async {
        final result = Completer<UpdateInfo?>();
        final store = _Store();
        final notices = AppNoticeController();
        addTearDown(notices.dispose);
        Future<void>? pull;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appSettingsProvider.overrideWithValue(
                const AsyncData(AppSettingsModel.defaults()),
              ),
              librarySyncControllerProvider.overrideWith(_Sync.new),
              updateServiceProvider.overrideWithValue(UpdateService()),
              updateRepositoryProvider.overrideWithValue(
                _Repository(store, result),
              ),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: AppNoticeScope(
                notifier: notices,
                child: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () => pull = triggerLibrarySyncFromPull(ref),
                    child: const Text('Pull'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pull'));
        await tester.pump();
        await pull;
        expect(result.isCompleted, isFalse);
        expect(store.forces, [true]);
        expect(notices.notice, isNull);
        if (outcome == 'disposed') await tester.pumpWidget(const SizedBox());
        if (outcome == 'error') {
          result.completeError(StateError('offline'));
        } else {
          result.complete(outcome == 'none' ? null : _update);
        }
        await tester.pump();
        await tester.pump();
        if (outcome == 'update') {
          expect(notices.notice?.message, 'Update available');
          expect(notices.notice?.level, AppNoticeLevel.info);
          expect(notices.notice?.onAction, isNotNull);
          notices.notice!.onAction!();
          await tester.pumpAndSettle();
          expect(find.text('Update Available'), findsOneWidget);
        } else {
          expect(notices.notice, isNull);
        }
        notices.dismiss();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final disabled in ['master', 'updates', 'updates.automatic']) {
    testWidgets('pull respects $disabled switch', (tester) async {
      final store = _Store();
      final result = Completer<UpdateInfo?>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            integrationPolicyProvider.overrideWithValue(
              IntegrationPolicy(
                masterEnabled: disabled != 'master',
                disabledKeys: disabled == 'master' ? {} : {disabled},
                lastFmVerified: false,
                listenBrainzVerified: false,
              ),
            ),
            updateRepositoryProvider.overrideWithValue(
              _Repository(store, result),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => checkForUpdatesFromPull(ref),
                child: const Text('Pull'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pull'));
      await tester.pump();
      expect(store.forces, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
