import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/run_outside_widget_build.dart';

import '../../helpers/stub_library_sync_engine.dart';
import '../../helpers/test_database.dart';

class _ConfigSource extends Notifier<AsyncValue<ServerConfigModel?>> {
  @override
  AsyncValue<ServerConfigModel?> build() => const AsyncData(null);

  // A setter would hide that this simulates a sign-in or sign-out.
  // ignore: use_setters_to_change_properties
  void set(AsyncValue<ServerConfigModel?> value) => state = value;
}

final _configSource =
    NotifierProvider<_ConfigSource, AsyncValue<ServerConfigModel?>>(
      _ConfigSource.new,
    );

const _alice = ServerConfigModel(
  url: 'https://example.com',
  username: 'alice',
  password: 'secret',
  apiVersion: '1.16.1',
);

void main() {
  group('server-config listeners during the first widget build', () {
    late ProviderContainer container;
    late StubLibrarySyncEngine engine;
    var pingCalls = 0;

    setUp(() {
      pingCalls = 0;
      final database = createTestDatabase();
      addTearDown(database.close);
      engine = StubLibrarySyncEngine.returning(
        LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.utc(2026, 8, 4),
        ),
      );
      container = ProviderContainer(
        overrides: [
          syncIntervalMinutesProvider.overrideWithValue(0),
          navisDatabaseProvider.overrideWithValue(database),
          requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
          serverConfigStateProvider.overrideWith(
            (ref) => ref.watch(_configSource),
          ),
          connectivityProvider.overrideWith((_) => const Stream.empty()),
          pingServerProvider.overrideWithValue(() async {
            pingCalls++;
            return '1.16.1';
          }),
          librarySyncEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);
      container.listen(serverReachabilityControllerProvider, (_, _) {});
      container.listen(librarySyncControllerProvider, (_, _) {});
    });

    Future<void> settleAndDispose(WidgetTester tester) async {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> buildFirstFrame(WidgetTester tester) => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            // The router's first read in NavisApp.build: it flushes the
            // stale session config and, with it, both listeners.
            ref.watch(serverConfigStateProvider);
            return const SizedBox();
          },
        ),
      ),
    );

    testWidgets('a session that appears stale is applied after the build', (
      tester,
    ) async {
      container.read(_configSource.notifier).set(const AsyncData(_alice));
      await buildFirstFrame(tester);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      expect(tester.takeException(), isNull);
      expect(pingCalls, greaterThanOrEqualTo(1));
      expect(engine.requests, isNotEmpty);
      await settleAndDispose(tester);
    });

    testWidgets('a sign-out that appears stale resets both controllers', (
      tester,
    ) async {
      final source = container.read(_configSource.notifier);
      source.set(const AsyncData(_alice));
      container.read(serverConfigStateProvider); // settle outside a build
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      final requestsBefore = engine.requests.length;
      final pingsBefore = pingCalls;

      source.set(const AsyncData(null));
      await buildFirstFrame(tester);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      expect(tester.takeException(), isNull);
      expect(
        container.read(librarySyncControllerProvider).status,
        LibrarySyncStatus.idle,
      );
      expect(
        container.read(serverReachabilityControllerProvider).status,
        ServerReachabilityStatus.checking,
      );
      expect(engine.requests.length, requestsBefore);
      expect(pingCalls, pingsBefore);
      await settleAndDispose(tester);
    });
  });

  group('runOutsideWidgetBuild', () {
    late List<String> log;
    late Ref capturedRef;

    ProviderContainer makeContainer() {
      final container = ProviderContainer();
      final probe = Provider<int>((ref) {
        capturedRef = ref;
        return 0;
      });
      container.read(probe);
      return container;
    }

    setUp(() => log = <String>[]);

    testWidgets('defers inside a build, in order, and runs outside at once', (
      tester,
    ) async {
      final container = makeContainer();
      addTearDown(container.dispose);

      runOutsideWidgetBuild(capturedRef, () => log.add('sync'));
      expect(log, ['sync']);

      await tester.pumpWidget(
        Builder(
          builder: (context) {
            runOutsideWidgetBuild(capturedRef, () => log.add('first'));
            runOutsideWidgetBuild(capturedRef, () => log.add('second'));
            log.add('built');
            return const SizedBox();
          },
        ),
      );
      // 'built' before 'first': the bodies were deferred, not run in build.
      expect(log, ['sync', 'built', 'first', 'second']);
    });

    testWidgets('skips a deferred body whose ref was disposed', (tester) async {
      final container = makeContainer();
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            runOutsideWidgetBuild(capturedRef, () => log.add('ran'));
            container.dispose();
            return const SizedBox();
          },
        ),
      );
      expect(log, isEmpty);
    });
  });
}
