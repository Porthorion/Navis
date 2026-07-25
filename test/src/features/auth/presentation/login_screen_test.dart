import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/data/server_connection_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _StaticReachabilityController extends ServerReachabilityController {
  _StaticReachabilityController(this._state);

  final ServerReachabilityState _state;

  @override
  ServerReachabilityState build() => _state;
}

class _FakeServerConnectionService extends ServerConnectionService {
  _FakeServerConnectionService({
    ServerConnectionProbeResult? result,
    this.error,
    this.completer,
  }) : _result =
           result ??
           const ServerConnectionProbeResult(
             apiVersion: '1.16.1',
             useLegacyAuth: false,
             capabilities: ServerCapabilities(),
           );

  final ServerConnectionProbeResult _result;
  final Exception? error;
  final Completer<ServerConnectionProbeResult>? completer;

  int callCount = 0;

  @override
  Future<ServerConnectionProbeResult> probe({
    required String url,
    required String username,
    required String password,
  }) async {
    callCount++;
    if (error != null) {
      throw error!;
    }
    if (completer != null) {
      return completer!.future;
    }
    return _result;
  }
}

class _TestServerConfigNotifier extends ServerConfigNotifier {
  ServerConfigModel? _savedConfig;

  @override
  Future<ServerConfigModel?> build() async => null;

  @override
  Future<void> save(ServerConfigModel config) async {
    _savedConfig = config;
    state = AsyncData(config);
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> clear() async {
    state = const AsyncData(null);
  }

  ServerConfigModel? savedConfigSnapshot() => _savedConfig;
}

class _StaticLibrarySyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return const LibrarySyncState.idle();
  }

  @override
  Future<LibrarySyncState> syncNow() async {
    return const LibrarySyncState.idle();
  }
}

class _StaticScrobbleDispatchController extends ScrobbleDispatchController {
  @override
  int build() => 0;
}

Widget _buildTestApp({
  required NavisDatabase database,
  required List<Object> overrides,
}) {
  return ProviderScope(
    overrides: [
      navisDatabaseProvider.overrideWithValue(database),
      scrobbleDispatchControllerProvider.overrideWith(
        _StaticScrobbleDispatchController.new,
      ),
      ...overrides.cast(),
    ],
    child: testNavisApp,
  );
}

Future<void> _disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Drift stream disposal can schedule microtask/zero-delay timers; flush them.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  late NavisDatabase database;

  setUp(() {
    database = createTestDatabase();
  });

  tearDown(() async {
    await database.close();
  });

  testWidgets('renders login form fields and actions', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        database: database,
        overrides: [
          serverConfigProvider.overrideWith(_TestServerConfigNotifier.new),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Navis'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Test connection'), findsNothing);
    expect(find.text('Connect'), findsOneWidget);
    await _disposeApp(tester);
  });

  testWidgets('uses centered constrained layout on wide displays', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _buildTestApp(
        database: database,
        overrides: [
          serverConfigProvider.overrideWith(_TestServerConfigNotifier.new),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Card), findsOneWidget);
    await _disposeApp(tester);
  });

  testWidgets('shows validation errors when required fields are empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildTestApp(
        database: database,
        overrides: [
          serverConfigProvider.overrideWith(_TestServerConfigNotifier.new),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Server URL is required.'), findsOneWidget);
    expect(find.text('Username is required.'), findsOneWidget);
    expect(find.text('Password is required.'), findsOneWidget);
    await _disposeApp(tester);
  });

  testWidgets('shows loading state while connecting', (tester) async {
    final completer = Completer<ServerConnectionProbeResult>();
    final fakeService = _FakeServerConnectionService(completer: completer);

    await tester.pumpWidget(
      _buildTestApp(
        database: database,
        overrides: [
          serverConfigProvider.overrideWith(_TestServerConfigNotifier.new),
          serverConnectionServiceProvider.overrideWithValue(fakeService),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'https://x.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'alice');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret');

    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(find.text('Connecting...'), findsOneWidget);
    expect(fakeService.callCount, 1);

    completer.complete(
      const ServerConnectionProbeResult(
        apiVersion: '1.16.1',
        useLegacyAuth: false,
        capabilities: ServerCapabilities(),
      ),
    );
    await tester.pumpAndSettle();

    await _disposeApp(tester);
  });

  testWidgets('submits connect when done is pressed on password field', (
    tester,
  ) async {
    final fakeService = _FakeServerConnectionService();

    await tester.pumpWidget(
      _buildTestApp(
        database: database,
        overrides: [
          serverConfigProvider.overrideWith(_TestServerConfigNotifier.new),
          serverConnectionServiceProvider.overrideWithValue(fakeService),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'https://x.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'alice');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret');
    await tester.tap(find.byType(TextFormField).at(2));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(fakeService.callCount, 1);
    await _disposeApp(tester);
  });

  testWidgets('successful connect saves config and navigates to home', (
    tester,
  ) async {
    late _TestServerConfigNotifier notifier;
    final fakeService = _FakeServerConnectionService();

    await tester.pumpWidget(
      _buildTestApp(
        database: database,
        overrides: [
          serverConnectionServiceProvider.overrideWithValue(fakeService),
          serverConfigProvider.overrideWith(
            () => notifier = _TestServerConfigNotifier(),
          ),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.online,
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
          homeRecentlyPlayedProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeFrequentAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'https://x.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'alice');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret');

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsWidgets);
    final savedConfig = notifier.savedConfigSnapshot();
    expect(savedConfig, isNotNull);
    expect(savedConfig?.url, 'https://x.test');
    expect(savedConfig?.username, 'alice');
    expect(savedConfig?.password, 'secret');
    await _disposeApp(tester);
  });

  testWidgets('connection errors are shown as user-safe message', (
    tester,
  ) async {
    final fakeService = _FakeServerConnectionService(
      error: const SubsonicConnectionException('socket timeout'),
    );

    await tester.pumpWidget(
      _buildTestApp(
        database: database,
        overrides: [
          serverConfigProvider.overrideWith(_TestServerConfigNotifier.new),
          serverConnectionServiceProvider.overrideWithValue(fakeService),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'https://x.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'alice');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret');
    await tester.ensureVisible(find.text('Connect'));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not reach server. Check URL and network.'),
      findsOneWidget,
    );
    await _disposeApp(tester);
  });

  testWidgets('allows HTTP server URL and shows insecure transport warning', (
    tester,
  ) async {
    late _TestServerConfigNotifier notifier;
    final fakeService = _FakeServerConnectionService();

    await tester.pumpWidget(
      _buildTestApp(
        database: database,
        overrides: [
          serverConnectionServiceProvider.overrideWithValue(fakeService),
          serverConfigProvider.overrideWith(
            () => notifier = _TestServerConfigNotifier(),
          ),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.online,
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
          homeRecentlyPlayedProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeFrequentAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'http://x.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'alice');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret');
    expect(find.textContaining('HTTP does not encrypt'), findsOneWidget);
    await tester.ensureVisible(find.text('Connect'));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(notifier.savedConfigSnapshot()?.url, 'http://x.test');
    await _disposeApp(tester);
  });
}
