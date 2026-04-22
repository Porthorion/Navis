import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/auth/data/server_connection_service.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/server_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

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
  _TestServerConfigNotifier(this._initial);

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

  @override
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

  testWidgets('screen is read-only (no form fields or save button)', (
    tester,
  ) async {
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
    expect(find.text('Save'), findsNothing);
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
}) {
  return ProviderScope(
    overrides: [
      serverConfigProvider.overrideWith(() => configNotifier),
      serverConnectionServiceProvider.overrideWithValue(connectionService),
      signOutServiceProvider.overrideWithValue(signOutService),
      // Treat key as bundled so External Services section shows no editable
      // fields or Save button — keeping existing assertions valid.
      lastFmBundledKeyProvider.overrideWithValue(true),
      // Provide in-memory settings so the screen doesn't spin on loading.
      appSettingsProvider.overrideWith(
        (_) => Stream.value(const AppSettingsModel.defaults()),
      ),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ServerSettingsScreen(),
    ),
  );
}
