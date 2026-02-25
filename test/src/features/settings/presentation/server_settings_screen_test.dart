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
import 'package:navis/src/features/settings/presentation/server_settings_screen.dart';

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
      ProviderScope(
        overrides: [
          serverConfigProvider.overrideWith(
            () => _TestServerConfigNotifier(initialConfig),
          ),
          serverConnectionServiceProvider.overrideWithValue(fakeConnection),
          signOutServiceProvider.overrideWithValue(fakeSignOut),
        ],
        child: _buildTestApp(),
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
      ProviderScope(
        overrides: [
          serverConfigProvider.overrideWith(
            () => _TestServerConfigNotifier(initialConfig),
          ),
          serverConnectionServiceProvider.overrideWithValue(fakeConnection),
          signOutServiceProvider.overrideWithValue(fakeSignOut),
        ],
        child: _buildTestApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(fakeConnection.callCount, 1);
    expect(find.text('Connection successful (API 1.16.1).'), findsOneWidget);
  });

  testWidgets('screen is read-only (no form fields or save button)', (
    tester,
  ) async {
    final fakeConnection = _FakeServerConnectionService();
    final fakeSignOut = _FakeSignOutService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverConfigProvider.overrideWith(
            () => _TestServerConfigNotifier(initialConfig),
          ),
          serverConnectionServiceProvider.overrideWithValue(fakeConnection),
          signOutServiceProvider.overrideWithValue(fakeSignOut),
        ],
        child: _buildTestApp(),
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
      ProviderScope(
        overrides: [
          serverConfigProvider.overrideWith(
            () => _TestServerConfigNotifier(initialConfig),
          ),
          serverConnectionServiceProvider.overrideWithValue(fakeConnection),
          signOutServiceProvider.overrideWithValue(fakeSignOut),
        ],
        child: _buildTestApp(),
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

Widget _buildTestApp() {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const ServerSettingsScreen(),
  );
}
