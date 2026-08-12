import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/presentation/initial_server_sync_provider.dart';
import 'package:navis/src/features/auth/presentation/initial_server_sync_screen.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:riverpod/src/framework.dart' show Override;

class _StaticInitialSyncController extends InitialServerSyncController {
  _StaticInitialSyncController(this.initial);

  final InitialServerSyncState initial;
  int retryCalls = 0;
  int mobileCalls = 0;
  int cancelCalls = 0;

  @override
  InitialServerSyncState build() => initial;

  @override
  Future<void> retry() async => retryCalls += 1;

  @override
  Future<void> startUsingMobileData() async => mobileCalls += 1;

  @override
  Future<void> cancelAndLogOut() async => cancelCalls += 1;
}

class _StaticLibrarySyncController extends LibrarySyncController {
  _StaticLibrarySyncController(this.initial);

  final LibrarySyncState initial;

  @override
  LibrarySyncState build() => initial;
}

Widget _testApp({
  required _StaticInitialSyncController setup,
  LibrarySyncState sync = const LibrarySyncState.idle(),
}) {
  return ProviderScope(
    overrides: <Override>[
      initialServerSyncControllerProvider.overrideWith(() => setup),
      librarySyncControllerProvider.overrideWith(
        () => _StaticLibrarySyncController(sync),
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
  testWidgets('offline state offers retry and cancel in focus order', (
    tester,
  ) async {
    final setup = _StaticInitialSyncController(
      const InitialServerSyncState(
        status: InitialServerSyncStatus.waitingForNetwork,
      ),
    );
    await tester.pumpWidget(_testApp(setup: setup));
    await tester.pumpAndSettle();

    expect(find.text('Initial server sync'), findsOneWidget);
    expect(
      find.text(
        "Navis is building this server's local library. Do not close the app during setup.",
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('initialSyncRetryButton')), findsOne);
    expect(find.byKey(const ValueKey('initialSyncCancelButton')), findsOne);

    await tester.tap(find.byKey(const ValueKey('initialSyncRetryButton')));
    await tester.pump();
    expect(setup.retryCalls, 1);
    await tester.tap(find.byKey(const ValueKey('initialSyncCancelButton')));
    await tester.pump();
    expect(setup.cancelCalls, 1);
  });

  testWidgets('metered state requires explicit mobile-data consent', (
    tester,
  ) async {
    final setup = _StaticInitialSyncController(
      const InitialServerSyncState(
        status: InitialServerSyncStatus.waitingForMobileConsent,
      ),
    );
    await tester.pumpWidget(_testApp(setup: setup));
    await tester.pumpAndSettle();

    expect(find.text('Sync using mobile data'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('initialSyncUseMobileDataButton')),
    );
    await tester.pump();
    expect(setup.mobileCalls, 1);
  });

  testWidgets('running state exposes determinate progress semantics', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    final setup = _StaticInitialSyncController(
      const InitialServerSyncState(status: InitialServerSyncStatus.running),
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

    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, 0.5);
    expect(find.text('Scanning songs'), findsOneWidget);
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('initialSyncProgressSemantics')),
    );
    expect(semantics.value, '2 / 4');
    semanticsHandle.dispose();
  });

  testWidgets('phone waiting state component golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final setup = _StaticInitialSyncController(
      const InitialServerSyncState(
        status: InitialServerSyncStatus.waitingForNetwork,
      ),
    );
    await tester.pumpWidget(_testApp(setup: setup));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const ValueKey('initialSyncCard')),
      matchesGoldenFile('goldens/initial_sync_waiting_phone.png'),
    );
  });

  testWidgets('desktop running state component golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final setup = _StaticInitialSyncController(
      const InitialServerSyncState(status: InitialServerSyncStatus.running),
    );
    await tester.pumpWidget(
      _testApp(
        setup: setup,
        sync: const LibrarySyncState(
          status: LibrarySyncStatus.running,
          stage: LibrarySyncStage.validatingCandidate,
          processed: 3,
          total: 8,
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey('initialSyncCard')),
      matchesGoldenFile('goldens/initial_sync_running_desktop.png'),
    );
  });
}
