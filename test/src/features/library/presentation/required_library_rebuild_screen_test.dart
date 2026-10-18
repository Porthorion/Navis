import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_screen.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

class _StaticRequiredRebuildController
    extends RequiredLibraryRebuildController {
  new(this.initial) : super(RequiredLibraryRebuildReason.initialLogin);

  final RequiredLibraryRebuildState initial;
  int retryCalls = 0;
  int mobileCalls = 0;
  int cancelCalls = 0;

  @override
  RequiredLibraryRebuildState build() => initial;

  @override
  Future<void> retry() async => retryCalls += 1;

  @override
  Future<void> startUsingMobileData() async => mobileCalls += 1;

  @override
  Future<void> cancelAndSignOut() async => cancelCalls += 1;
}

class _StaticLibrarySyncController extends LibrarySyncController {
  new(this.initial);

  final LibrarySyncState initial;

  @override
  LibrarySyncState build() => initial;
}

Widget _testApp({
  _StaticRequiredRebuildController? setup,
  LibrarySyncState sync = const LibrarySyncState.idle(),
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: <Override>[
      ...overrides,
      if (setup != null)
        requiredLibraryRebuildControllerProvider(
          RequiredLibraryRebuildReason.initialLogin,
        ).overrideWith(() => setup),
      librarySyncControllerProvider.overrideWith(
        () => _StaticLibrarySyncController(sync),
      ),
      onboardingVersionProvider.overrideWithValue(
        const AsyncData(currentOnboardingVersion),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const RequiredLibraryRebuildScreen(
        reason: RequiredLibraryRebuildReason.initialLogin,
      ),
    ),
  );
}

void main() {
  for (final offline in [false, true]) {
    testWidgets(
      offline
          ? 'offline policy shows Retry while ping is pending'
          : 'pending ping hides Retry until confirmed unreachable',
      (tester) async {
        final firstPing = Completer<String>();
        final secondPing = Completer<String>();
        var probes = 0;
        await tester.pumpWidget(
          _testApp(
            overrides: [
              serverConfigStateProvider.overrideWithValue(
                const AsyncData(
                  ServerConfigModel(
                    id: 1,
                    url: 'https://example.test',
                    username: 'fixture',
                    password: 'fixture',
                    apiVersion: '1.16.1',
                  ),
                ),
              ),
              pingServerProvider.overrideWithValue(
                () => ++probes == 1 ? firstPing.future : secondPing.future,
              ),
              connectivityProvider.overrideWith((_) => const Stream.empty()),
              reachabilityQuickRetryIntervalProvider.overrideWithValue(
                const Duration(milliseconds: 1),
              ),
              syncNetworkPolicyProvider.overrideWithValue(
                resolveSyncNetworkPolicy(
                  networkType: offline ? NetworkType.offline : NetworkType.wifi,
                  nativeMetered: false,
                  backgroundSyncUnmeteredOnly: true,
                ),
              ),
            ],
          ),
        );
        await tester.pump();
        final retry = find.byKey(const ValueKey('requiredSyncRetry'));
        const offlineText =
            'Connect to a network, then retry to continue setup.';
        if (offline) {
          expect(retry, findsOneWidget);
          expect(find.text(offlineText), findsOneWidget);
        } else {
          expect(retry, findsNothing);
          expect(find.text(offlineText), findsNothing);
          expect(find.text('Preparing library'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);

          firstPing.completeError(Exception('First probe failed'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 1));
          expect(probes, 2);
          expect(retry, findsNothing);
          secondPing.completeError(Exception('Confirmed failure'));
          await tester.pump();
          await tester.pump();
          expect(retry, findsOneWidget);
          expect(find.text(offlineText), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('offline required setup offers retry and cancel-and-sign-out', (
    tester,
  ) async {
    final setup = _StaticRequiredRebuildController(
      const RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.waitingForNetwork,
      ),
    );
    await tester.pumpWidget(_testApp(setup: setup));
    await tester.pump();

    expect(find.text('Building Your Library'), findsOneWidget);
    expect(
      find.text('Navis is preparing this server for the first time.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('requiredSyncRetry')), findsOneWidget);
    expect(find.byKey(const ValueKey('requiredSyncSignOut')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('requiredSyncRetry')));
    await tester.pump();
    expect(setup.retryCalls, 1);
    await tester.tap(find.byKey(const ValueKey('requiredSyncSignOut')));
    await tester.pump();
    expect(setup.cancelCalls, 1);
  });

  testWidgets('a failed first setup says so once, in setup wording', (
    tester,
  ) async {
    final setup = _StaticRequiredRebuildController(
      const RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.failed,
        failure: RequiredLibraryRebuildFailure.incomplete,
      ),
    );

    await tester.pumpWidget(_testApp(setup: setup));
    await tester.pump();

    expect(find.text('Your library could not be set up.'), findsOneWidget);
    expect(find.textContaining('rebuild'), findsNothing);
    expect(find.byKey(const ValueKey('requiredSyncRetry')), findsOneWidget);
  });

  testWidgets('a failed setup shows the server explanation', (tester) async {
    await tester.pumpWidget(
      _testApp(
        setup: _StaticRequiredRebuildController(
          const RequiredLibraryRebuildState(
            status: RequiredLibraryRebuildStatus.failed,
            failure: RequiredLibraryRebuildFailure.incomplete,
            errorMessage: 'The server is rebuilding its index.',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('The server is rebuilding its index.'), findsOneWidget);
  });

  testWidgets('a setup that could not sign out says so', (tester) async {
    await tester.pumpWidget(
      _testApp(
        setup: _StaticRequiredRebuildController(
          const RequiredLibraryRebuildState(
            status: RequiredLibraryRebuildStatus.failed,
            failure: RequiredLibraryRebuildFailure.signOutFailed,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Signing out did not finish. Try again.'), findsOneWidget);
  });

  testWidgets('metered setup requires explicit mobile-data consent', (
    tester,
  ) async {
    final setup = _StaticRequiredRebuildController(
      const RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.waitingForMobileConsent,
      ),
    );
    await tester.pumpWidget(_testApp(setup: setup));
    await tester.pump();

    expect(find.text('Sync Using Mobile Data'), findsOneWidget);
    expect(find.byKey(const ValueKey('requiredSyncRetry')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('requiredSyncUseMobileData')));
    await tester.pump();
    expect(setup.mobileCalls, 1);
  });

  testWidgets('required setup shows circular determinate progress and stage', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    final setup = _StaticRequiredRebuildController(
      const RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.syncing,
      ),
    );
    await tester.pumpWidget(
      _testApp(
        setup: setup,
        sync: const LibrarySyncState(
          status: LibrarySyncStatus.running,
          stage: LibrarySyncStage.fetchingSongs,
          processed: 2,
          total: 4,
        ),
      ),
    );
    await tester.pump();

    final progress = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(progress.value, 0.5);
    expect(
      tester.getSize(
        find.byKey(const ValueKey<String>('requiredSyncProgressRing')),
      ),
      const Size.square(128),
    );
    expect(tester.widget<NavisIcon>(find.byType(NavisIcon)).size, 132);
    expect(find.text('Getting song index'), findsOneWidget);
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('requiredSyncProgressSemantics')),
    );
    expect(semantics.value, '2 / 4');
    semanticsHandle.dispose();
  });

  testWidgets('required setup uses indeterminate progress for unknown totals', (
    tester,
  ) async {
    final setup = _StaticRequiredRebuildController(
      const RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.syncing,
      ),
    );
    await tester.pumpWidget(
      _testApp(
        setup: setup,
        sync: const LibrarySyncState(
          status: LibrarySyncStatus.running,
          stage: LibrarySyncStage.fetchingAlbums,
        ),
      ),
    );
    await tester.pump();

    final progress = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(progress.value, isNull);
    expect(find.text('Syncing albums'), findsOneWidget);
  });
}
