import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/auth/data/server_connection_service.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/server_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository {}

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

class _FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  final launchedUrls = <String>[];
  bool canLaunchResponse = true;
  bool launchResponse = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => canLaunchResponse;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrls.add(url);
    return launchResponse;
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launchedUrls.add(url);
    return launchResponse;
  }
}

class _FakeListenBrainzApiClient extends ListenBrainzApiClient {
  _FakeListenBrainzApiClient({required this.valid});

  final bool valid;

  @override
  Future<bool> validateToken(String userToken) async => valid;
}

class _MemoryExternalScrobbleCredentialStore
    implements ExternalScrobbleCredentialStore {
  String? listenBrainzToken;

  @override
  Future<void> clearListenBrainzToken() async => listenBrainzToken = null;

  @override
  Future<String?> readListenBrainzToken() async => listenBrainzToken;

  @override
  Future<void> saveListenBrainzToken(String value) async {
    listenBrainzToken = value;
  }
}

Finder _textFieldWithLabel(String label) {
  return find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );
}

void main() {
  late UrlLauncherPlatform defaultUrlLauncher;
  late _FakeUrlLauncherPlatform urlLauncher;

  setUpAll(() {
    registerFallbackValue(const AppSettingsModel.defaults());
  });

  setUp(() {
    defaultUrlLauncher = UrlLauncherPlatform.instance;
    urlLauncher = _FakeUrlLauncherPlatform();
    UrlLauncherPlatform.instance = urlLauncher;
  });

  tearDown(() {
    UrlLauncherPlatform.instance = defaultUrlLauncher;
  });

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

  testWidgets('renders external service configuration fields', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        configNotifier: _TestServerConfigNotifier(initialConfig),
        connectionService: _FakeServerConnectionService(),
        signOutService: _FakeSignOutService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(_textFieldWithLabel('API Key'), findsNothing);
    expect(_textFieldWithLabel('Shared secret'), findsNothing);
    expect(_textFieldWithLabel('User token'), findsOneWidget);
    expect(find.textContaining('Last.fm'), findsNothing);
    expect(find.text('ListenBrainz'), findsOneWidget);
    expect(find.text('Get Token'), findsOneWidget);
  });

  testWidgets('valid ListenBrainz token saves securely and marks usable', (
    tester,
  ) async {
    final repository = _MockSettingsRepository();
    final credentialStore = _MemoryExternalScrobbleCredentialStore();
    AppSettingsModel? savedModel;

    when(() => repository.saveSettings(any())).thenAnswer((invocation) async {
      savedModel = invocation.positionalArguments.first as AppSettingsModel;
    });

    await tester.pumpWidget(
      _buildTestApp(
        configNotifier: _TestServerConfigNotifier(initialConfig),
        connectionService: _FakeServerConnectionService(),
        signOutService: _FakeSignOutService(),
        settingsRepository: repository,
        credentialStore: credentialStore,
        listenBrainzClient: _FakeListenBrainzApiClient(valid: true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(_textFieldWithLabel('User token'), 'valid-token');
    final validateButton = find.widgetWithText(
      FilledButton,
      'Validate and save',
    );
    await tester.scrollUntilVisible(
      validateButton,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(validateButton);
    await tester.pumpAndSettle();

    expect(credentialStore.listenBrainzToken, 'valid-token');
    expect(savedModel, isNotNull);
    expect(savedModel!.listenBrainzTokenValid, isTrue);
    expect(savedModel!.listenBrainzScrobblingEnabled, isTrue);
    expect(find.text('ListenBrainz token validated.'), findsOneWidget);
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

  testWidgets('server details are read-only static text', (
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
  SettingsRepository? settingsRepository,
  ExternalScrobbleCredentialStore? credentialStore,
  AppSettingsModel initialSettings = const AppSettingsModel.defaults(),
  ListenBrainzApiClient? listenBrainzClient,
}) {
  final overrides = [
    serverConfigProvider.overrideWith(() => configNotifier),
    serverConnectionServiceProvider.overrideWithValue(connectionService),
    signOutServiceProvider.overrideWithValue(signOutService),
    if (settingsRepository != null)
      settingsRepositoryProvider.overrideWithValue(settingsRepository),
    if (credentialStore != null)
      externalScrobbleCredentialStoreProvider.overrideWithValue(
        credentialStore,
      ),
    if (listenBrainzClient != null)
      listenBrainzApiClientProvider.overrideWithValue(listenBrainzClient),
    // Provide in-memory settings so the screen doesn't spin on loading.
    appSettingsProvider.overrideWith((_) => Stream.value(initialSettings)),
  ];

  return ProviderScope(
    overrides: overrides,
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ServerSettingsScreen(),
    ),
  );
}
