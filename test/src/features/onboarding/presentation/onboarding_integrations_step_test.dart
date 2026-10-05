import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_screen.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

class _FakeLastFmApiClient extends LastFmApiClient {
  new(this._result) : super(apiKey: 'typed-key');

  final LastFmApiKeyValidationResult _result;

  @override
  Future<LastFmApiKeyValidationResult> validateApiKey() async => _result;
}

class _FakeListenBrainzApiClient extends ListenBrainzApiClient {
  new({required this.valid});

  final bool valid;
  final userInitiatedCalls = <bool>[];

  @override
  Future<ListenBrainzTokenDetails> validateTokenDetails(
    String userToken, {
    bool userInitiated = false,
  }) async {
    userInitiatedCalls.add(userInitiated);
    return ListenBrainzTokenDetails(
      valid: valid,
      userName: valid ? 'navis-user' : null,
    );
  }
}

class _MemoryCredentialStore implements ExternalScrobbleCredentialStore {
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

class _Harness {
  const new(this.tester, this.database, this.credentials);

  final WidgetTester tester;
  final NavisDatabase database;
  final _MemoryCredentialStore credentials;

  Future<AppSettingsTableData> row() async =>
      (await tester.runAsync(database.appSettingsDao.getSettings))!;

  Finder service(IntegrationService service) => find.byKey(
    ValueKey<String>('onboarding-integrations-service-${service.key}'),
  );

  SwitchListTile serviceTile(IntegrationService service) =>
      tester.widget<SwitchListTile>(this.service(service));

  Finder get master =>
      find.byKey(const ValueKey<String>('onboarding-integrations-master'));

  Finder get token =>
      find.byKey(const ValueKey<String>('onboarding-listenbrainz-token'));

  Finder get lastFmKey =>
      find.byKey(const ValueKey<String>('onboarding-lastfm-key'));

  Future<void> tap(Finder finder) async {
    await tester.tap(finder);
    await settle();
  }

  /// Lets database writes finish and the settings stream deliver them.
  Future<void> settle() async {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<void> openIntegrationsStep() async {
    for (var step = 0; step < 3; step++) {
      await tap(find.text('Continue'));
    }
    expect(find.text('Step 4 of 4'), findsOneWidget);
  }

  /// Finish waits a moment before leaving onboarding.
  Future<void> finish() async {
    await tap(find.text('Finish'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 300));
    await settle();
  }
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool lastFmBundled = true,
  Future<void> Function(AppSettingsDao dao)? seed,
  ListenBrainzApiClient? listenBrainzClient,
  LastFmApiClient Function(String)? lastFmClientFactory,
}) async {
  // Tall enough to build every row of the lazy step list.
  setAdaptiveTestViewport(tester, const Size(500, 2400));
  final database = createTestDatabase();
  await tester.runAsync(() async {
    await database.appSettingsDao.getSettings();
    await seed?.call(database.appSettingsDao);
  });
  final credentials = _MemoryCredentialStore();
  final container = ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        lastFmBundledKeyProvider.overrideWithValue(lastFmBundled),
        externalScrobbleCredentialStoreProvider.overrideWithValue(credentials),
        if (listenBrainzClient != null)
          listenBrainzApiClientProvider.overrideWithValue(listenBrainzClient),
        if (lastFmClientFactory != null)
          lastFmApiClientFactoryProvider.overrideWithValue(lastFmClientFactory),
      ],
    ),
  );
  final router = GoRouter(
    initialLocation: AppRoutes.onboarding,
    routes: [
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (_, _) => const OnboardingScreen(),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (_, _) => const Scaffold(body: Text('Home stub')),
      ),
    ],
  );
  addTearDown(() async {
    router.dispose();
    container.dispose();
    await database.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  final harness = _Harness(tester, database, credentials);
  await harness.settle();
  await harness.openIntegrationsStep();
  return harness;
}

void main() {
  testWidgets('offers the online services, each saying what it sends', (
    tester,
  ) async {
    final h = await _pump(tester);

    for (final line in <String>[
      'Integrations',
      'Online services',
      'Off: Navis only talks to your server.',
      'Sends artist and track names to api.deezer.com.',
      'Sends track and artist names to ws.audioscrobbler.com.',
      'Sends your listens and likes to api.listenbrainz.org.',
      'Sends track title, artist, album and duration to lrclib.net.',
      'Sends an app version check to git.porthorion.com.',
      'Fine-tune per feature in Settings › Integrations.',
    ]) {
      expect(find.text(line), findsOneWidget, reason: line);
    }
    // Feature-level and other services stay in Settings › Integrations.
    expect(find.text('Internet radio'), findsNothing);
    expect(find.text('Same Vibes mixes'), findsNothing);

    expect(tester.widget<SwitchListTile>(h.master).value, isTrue);
    for (final service in const [
      IntegrationService.deezer,
      IntegrationService.lastFm,
      IntegrationService.listenBrainz,
      IntegrationService.lrclib,
      IntegrationService.updates,
    ]) {
      final tile = h.serviceTile(service);
      expect(tile.value, isTrue, reason: service.key);
      expect(tile.onChanged, isNotNull, reason: service.key);
    }
    // A bundled key needs no field; ListenBrainz is on, so its token is.
    expect(h.lastFmKey, findsNothing);
    expect(h.token, findsOneWidget);
  });

  testWidgets('update checks are not offered on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final h = await _pump(tester);
      expect(h.service(IntegrationService.updates), findsNothing);
      expect(h.service(IntegrationService.lrclib), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the ListenBrainz token field follows its switch', (
    tester,
  ) async {
    final h = await _pump(tester);

    await h.tap(h.service(IntegrationService.listenBrainz));
    expect(h.serviceTile(IntegrationService.listenBrainz).value, isFalse);
    expect(h.token, findsNothing);

    await h.tap(h.service(IntegrationService.listenBrainz));
    expect(h.token, findsOneWidget);
  });

  testWidgets('Online services off locks every service and hides setup', (
    tester,
  ) async {
    final h = await _pump(tester, lastFmBundled: false);
    expect(h.lastFmKey, findsOneWidget);

    await h.tap(h.master);

    for (final service in const [
      IntegrationService.deezer,
      IntegrationService.lastFm,
      IntegrationService.listenBrainz,
      IntegrationService.lrclib,
    ]) {
      expect(h.serviceTile(service).onChanged, isNull, reason: service.key);
    }
    expect(find.text('Online services are off.'), findsNWidgets(5));
    expect(h.token, findsNothing);
    expect(h.lastFmKey, findsNothing);
  });

  testWidgets('a keyless build locks Last.fm until its key is verified', (
    tester,
  ) async {
    var result = const LastFmApiKeyValidationResult(
      valid: false,
      apiErrorCode: 10,
    );
    final h = await _pump(
      tester,
      lastFmBundled: false,
      lastFmClientFactory: (_) => _FakeLastFmApiClient(result),
    );

    final locked = h.serviceTile(IntegrationService.lastFm);
    expect(locked.value, isFalse);
    expect(locked.onChanged, isNull);
    expect(find.text('Needs a verified Last.fm API key.'), findsOneWidget);

    await tester.enterText(h.lastFmKey, 'bad-key');
    await h.tap(find.text('Validate key'));
    expect(
      tester.widget<TextField>(h.lastFmKey).decoration!.errorText,
      'Invalid Last.fm API key.',
    );
    expect(h.serviceTile(IntegrationService.lastFm).onChanged, isNull);

    result = const LastFmApiKeyValidationResult(valid: true);
    await tester.enterText(h.lastFmKey, 'good-key');
    await h.tap(find.text('Validate key'));
    expect(tester.widget<TextField>(h.lastFmKey).decoration!.errorText, isNull);
    final unlocked = h.serviceTile(IntegrationService.lastFm);
    expect(unlocked.value, isTrue);
    expect(unlocked.onChanged, isNotNull);
  });

  testWidgets('the token is checked as the user, with errors on the field', (
    tester,
  ) async {
    final client = _FakeListenBrainzApiClient(valid: false);
    final h = await _pump(tester, listenBrainzClient: client);

    // Done on the keyboard checks the token.
    await tester.tap(h.token);
    await tester.enterText(h.token, 'rejected-token');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await h.settle();

    expect(client.userInitiatedCalls, [true]);
    expect(
      tester.widget<TextField>(h.token).decoration!.errorText,
      'Invalid ListenBrainz token.',
    );
    expect(h.credentials.listenBrainzToken, isNull);
  });

  testWidgets('a valid token is stored and shown as connected', (tester) async {
    final client = _FakeListenBrainzApiClient(valid: true);
    final h = await _pump(tester, listenBrainzClient: client);

    expect(tester.widget<TextField>(h.token).obscureText, isTrue);
    await h.tap(find.byTooltip('Show'));
    expect(tester.widget<TextField>(h.token).obscureText, isFalse);

    await tester.enterText(h.token, 'good-token');
    await h.tap(find.text('Validate and connect'));

    expect(client.userInitiatedCalls, [true]);
    expect(h.credentials.listenBrainzToken, 'good-token');
    expect(find.text('Connected as navis-user.'), findsOneWidget);
    expect(tester.widget<TextField>(h.token).decoration!.errorText, isNull);
  });

  testWidgets('with Online services stored off, nothing can be checked yet', (
    tester,
  ) async {
    // Setup run again after turning Online services off: the guard reads
    // stored settings, so a check would be refused whatever the draft says.
    final client = _FakeListenBrainzApiClient(valid: true);
    final h = await _pump(
      tester,
      lastFmBundled: false,
      seed: (dao) => dao.setExternalIntegrationsEnabled(enabled: false),
      listenBrainzClient: client,
      lastFmClientFactory: (_) => throw StateError('no Last.fm check'),
    );
    expect(h.token, findsNothing);

    await h.tap(h.master);
    const message =
        'Online services are off on this device. Finish setup with them on, '
        'then connect in Settings › Integrations.';
    expect(tester.widget<TextField>(h.token).decoration!.helperText, message);
    expect(
      tester.widget<TextField>(h.lastFmKey).decoration!.helperText,
      message,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Validate and connect'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Validate key'),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(h.token);
    await tester.enterText(h.token, 'good-token');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await h.settle();
    expect(client.userInitiatedCalls, isEmpty);
    expect(h.credentials.listenBrainzToken, isNull);
  });

  testWidgets('Finish saves the choices and marks the 1.4.3 note seen', (
    tester,
  ) async {
    final h = await _pump(tester);

    await h.tap(h.service(IntegrationService.deezer));
    await h.tap(h.service(IntegrationService.lrclib));
    // Nothing is written before Finish.
    expect((await h.row()).disabledIntegrations, '[]');

    await h.finish();

    final row = await h.row();
    expect(find.text('Home stub'), findsOneWidget);
    expect(row.onboardingVersion, currentOnboardingVersion);
    expect(row.externalIntegrationsEnabled, isTrue);
    expect(parseDisabledIntegrationKeys(row.disabledIntegrations), {
      'deezer',
      'lrclib',
    });
    expect(row.integrationsNoticeDismissed, isTrue);
  });

  testWidgets('Finish with Online services off stores the master switch', (
    tester,
  ) async {
    final h = await _pump(tester);

    await h.tap(h.master);
    await h.finish();

    final row = await h.row();
    expect(row.externalIntegrationsEnabled, isFalse);
    expect(row.disabledIntegrations, '[]');
    expect(row.integrationsNoticeDismissed, isTrue);
  });

  testWidgets('Skip keeps the defaults and leaves the 1.4.3 note pending', (
    tester,
  ) async {
    final h = await _pump(tester);

    await h.tap(h.service(IntegrationService.deezer));
    await h.tap(h.master);
    await h.tap(find.text('Skip setup'));
    await h.tap(find.widgetWithText(FilledButton, 'Skip setup'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 300));
    await h.settle();

    final row = await h.row();
    expect(find.text('Home stub'), findsOneWidget);
    expect(row.onboardingVersion, currentOnboardingVersion);
    expect(row.externalIntegrationsEnabled, isTrue);
    expect(row.disabledIntegrations, '[]');
    expect(row.integrationsNoticeDismissed, isFalse);
  });
}
