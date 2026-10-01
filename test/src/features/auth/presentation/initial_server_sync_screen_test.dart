import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/auth/presentation/initial_server_sync_screen.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_provider.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:riverpod/src/framework.dart' show Override;

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
  required _StaticRequiredRebuildController setup,
  LibrarySyncState sync = const LibrarySyncState.idle(),
}) {
  return ProviderScope(
    overrides: <Override>[
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const InitialServerSyncScreen(),
    ),
  );
}

void main() {
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

    expect(find.text('Sync using mobile data'), findsOneWidget);
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
