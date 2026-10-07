import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/auth/data/server_connection_service.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/server_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_theme.dart';

class _FakeServerConnectionService extends ServerConnectionService {
  final result = const ServerConnectionProbeResult(
    apiVersion: '1.16.1',
    useLegacyAuth: false,
    capabilities: ServerCapabilities(),
  );
  int callCount = 0;

  @override
  Future<ServerConnectionProbeResult> probe({
    required String url,
    required String username,
    required String password,
  }) async {
    callCount++;
    return result;
  }
}

class _FakeSignOutService implements SignOutService {
  int callCount = 0;
  bool? lastWipeLocalData;

  @override
  Future<void> signOut({required bool wipeLocalData}) async {
    callCount++;
    lastWipeLocalData = wipeLocalData;
  }
}

class _TestServerConfigNotifier extends ServerConfigNotifier {
  new(this._initial);

  ServerConfigModel? _initial;
  ServerConfigModel? _savedConfig;

  @override
  Future<ServerConfigModel?> build() async => _initial;

  @override
  Future<void> save(ServerConfigModel config) async {
    _savedConfig = config;
    _initial = config;
    state = AsyncData(config);
  }

  @override
  Future<void> refresh() async {
    state = AsyncData(_initial);
  }

  Future<void> clear() async {
    _initial = null;
    state = const AsyncData(null);
  }

  ServerConfigModel? savedConfigSnapshot() => _savedConfig;
}

void main() {
  const initialConfig = ServerConfigModel(
    name: 'example.com',
    url: 'https://example.com',
    username: 'alice',
    password: 'secret',
    apiVersion: '1.16.1',
  );

  testWidgets('renders current server details', (tester) async {
    final fakeConnection = _FakeServerConnectionService();
    final fakeSignOut = _FakeSignOutService();

    await tester.pumpWidget(
      _buildTestApp(
        configNotifier: _TestServerConfigNotifier(initialConfig),
        connectionService: fakeConnection,
        signOutService: fakeSignOut,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current connection'), findsOneWidget);
    expect(find.textContaining('example.com'), findsWidgets);
    expect(find.text('https://example.com'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('uses a continuous workspace and Settings return on desktop', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1280, 800));

    await tester.pumpWidget(
      _buildTestApp(
        configNotifier: _TestServerConfigNotifier(initialConfig),
        connectionService: _FakeServerConnectionService(),
        signOutService: _FakeSignOutService(),
        desktopMode: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back'), findsOneWidget);
    final cardContext = tester.element(find.byType(Card).first);
    expect(Theme.of(cardContext).cardTheme.color, Colors.transparent);
  });

  testWidgets('is titled Server Information and has no Integrations link', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildTestApp(
        configNotifier: _TestServerConfigNotifier(initialConfig),
        connectionService: _FakeServerConnectionService(),
        signOutService: _FakeSignOutService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Server Information'),
      ),
      findsOneWidget,
    );
    expect(find.text('Configuration'), findsNothing);
    // Integrations is its own Settings entry, not repeated here.
    expect(find.text('Integrations'), findsNothing);
    expect(find.text('Online services'), findsNothing);
    expect(find.text('External Services'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Last.fm'), findsNothing);
    expect(find.text('ListenBrainz'), findsNothing);
  });

  testWidgets('does not render retired Listen Together configuration', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildTestApp(
        configNotifier: _TestServerConfigNotifier(initialConfig),
        connectionService: _FakeServerConnectionService(),
        signOutService: _FakeSignOutService(),
        initialSettings: const AppSettingsModel.defaults(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Listen Together'), findsNothing);
    expect(find.textContaining('Voyage'), findsNothing);
  });

  testWidgets('test connection action shows success', (tester) async {
    final fakeConnection = _FakeServerConnectionService();
    final fakeSignOut = _FakeSignOutService();

    await tester.pumpWidget(
      _buildTestApp(
        configNotifier: _TestServerConfigNotifier(initialConfig),
        connectionService: fakeConnection,
        signOutService: fakeSignOut,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test connection'));
    await tester.pump();

    expect(fakeConnection.callCount, 1);
  });

  testWidgets('server details are read-only static text', (tester) async {
    final fakeConnection = _FakeServerConnectionService();
    final fakeSignOut = _FakeSignOutService();

    await tester.pumpWidget(
      _buildTestApp(
        configNotifier: _TestServerConfigNotifier(initialConfig),
        connectionService: fakeConnection,
        signOutService: fakeSignOut,
      ),
    );
    await tester.pumpAndSettle();

    // Server details are displayed as static text, not editable form fields.
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('Current connection'), findsOneWidget);
    expect(find.text('https://example.com'), findsOneWidget);
  });

  testWidgets('sign out dialog presents both options', (tester) async {
    final fakeConnection = _FakeServerConnectionService();
    final fakeSignOut = _FakeSignOutService();

    await tester.pumpWidget(
      _buildTestApp(
        configNotifier: _TestServerConfigNotifier(initialConfig),
        connectionService: fakeConnection,
        signOutService: fakeSignOut,
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('Sign out (keep local data)'), findsOneWidget);
    expect(find.text('Sign out and clear local data'), findsOneWidget);
  });
}

Widget _buildTestApp({
  required ServerConfigNotifier configNotifier,
  required ServerConnectionService connectionService,
  required SignOutService signOutService,
  AppSettingsModel initialSettings = const AppSettingsModel.defaults(),
  bool desktopMode = false,
}) {
  return ProviderScope(
    overrides: [
      serverConfigProvider.overrideWith(() => configNotifier),
      serverConnectionServiceProvider.overrideWithValue(connectionService),
      signOutServiceProvider.overrideWithValue(signOutService),
      appSettingsProvider.overrideWith((_) => Stream.value(initialSettings)),
    ],
    child: MaterialApp(
      theme: testTheme(),
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: desktopMode
          ? AdaptiveContextScope(
              adaptiveContext: resolveAdaptiveContext(
                desktopRuntime: true,
                viewportSize: const Size(1280, 800),
                safePadding: EdgeInsets.zero,
              ),
              child: const ServerSettingsScreen(),
            )
          : const ServerSettingsScreen(),
    ),
  );
}
