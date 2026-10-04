import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/integrations/presentation/integrations_settings_screen.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

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
  new([this.listenBrainzToken]);

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
  const new(this.tester, this.database, this.container);

  final WidgetTester tester;
  final NavisDatabase database;
  final ProviderContainer container;

  Future<AppSettingsTableData> row() async =>
      (await tester.runAsync(database.appSettingsDao.getSettings))!;

  Finder feature(IntegrationFeature feature) =>
      find.byKey(ValueKey<String>('integrations-feature-${feature.key}'));

  Finder service(IntegrationService service) =>
      find.byKey(ValueKey<String>('integrations-service-${service.key}'));

  SwitchListTile featureTile(IntegrationFeature feature) =>
      tester.widget<SwitchListTile>(this.feature(feature));

  Switch serviceSwitch(IntegrationService service) =>
      tester.widget<Switch>(this.service(service));

  Future<void> tap(Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(finder);
    await settle();
  }

  /// Lets a database write finish and the settings stream deliver it.
  Future<void> settle() async {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Future<void> Function(AppSettingsDao dao)? seed,
  bool lastFmBundled = true,
  String lastFmApiKey = 'bundled-key',
  ExternalScrobbleCredentialStore? credentialStore,
  ListenBrainzApiClient? listenBrainzClient,
  LastFmApiClient Function(String)? lastFmClientFactory,
  // Tall enough to build every row of the lazy list.
  Size size = const Size(600, 5000),
  bool desktop = false,
  ThemeData? theme,
}) async {
  setAdaptiveTestViewport(tester, size);
  final database = createTestDatabase();
  await tester.runAsync(() async {
    await database.appSettingsDao.getSettings();
    await seed?.call(database.appSettingsDao);
  });
  final container = ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        lastFmBundledKeyProvider.overrideWithValue(lastFmBundled),
        lastFmApiKeyProvider.overrideWithValue(lastFmApiKey),
        externalScrobbleCredentialStoreProvider.overrideWithValue(
          credentialStore ?? _MemoryCredentialStore(),
        ),
        if (listenBrainzClient != null)
          listenBrainzApiClientProvider.overrideWithValue(listenBrainzClient),
        if (lastFmClientFactory != null)
          lastFmApiClientFactoryProvider.overrideWithValue(lastFmClientFactory),
      ],
    ),
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  const screen = IntegrationsSettingsScreen();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme ?? testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: desktop
            ? AdaptiveContextScope(
                adaptiveContext: resolveAdaptiveContext(
                  desktopRuntime: true,
                  viewportSize: size,
                  safePadding: EdgeInsets.zero,
                ),
                child: screen,
              )
            : screen,
      ),
    ),
  );
  final harness = _Harness(tester, database, container);
  await harness.settle();
  return harness;
}

Finder _textFieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  testWidgets('lists every service with what it sends and where', (
    tester,
  ) async {
    final h = await _pump(tester);

    for (final line in <String>[
      'Online services',
      'Off: Navis only talks to your server.',
      'Sends artist and track names to api.deezer.com.',
      'Sends track and artist names to ws.audioscrobbler.com.',
      'Key included with this build',
      'Sends your listens and likes to api.listenbrainz.org.',
      'Sends track title, artist, album and duration to lrclib.net.',
      'Sends an app version check to git.porthorion.com.',
      'Downloads headphone profiles from GitHub, only when you ask.',
      "Reads now-playing info from the station's server.",
      'Loads images your server links from other sites, such as artist photos.',
    ]) {
      await tester.scrollUntilVisible(
        find.text(line),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(line), findsOneWidget, reason: line);
    }
    for (final feature in IntegrationFeature.values) {
      expect(h.feature(feature), findsOneWidget, reason: feature.key);
    }
    for (final service in IntegrationService.values) {
      expect(h.service(service), findsOneWidget, reason: service.key);
    }
    // A bundled key needs no field.
    expect(_textFieldWithLabel('API Key'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every switch is on by default once credentials are verified', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      seed: (dao) => dao.updateListenBrainzScrobblingState(
        enabled: true,
        tokenValid: true,
      ),
    );

    for (final feature in IntegrationFeature.values) {
      final tile = h.featureTile(feature);
      expect(tile.value, isTrue, reason: feature.key);
      expect(tile.onChanged, isNotNull, reason: feature.key);
    }
    for (final service in IntegrationService.values) {
      expect(h.serviceSwitch(service).value, isTrue, reason: service.key);
      expect(h.serviceSwitch(service).onChanged, isNotNull);
    }
  });

  testWidgets('Same Vibes says plainly what on and off mean', (tester) async {
    final h = await _pump(tester);

    await tester.scrollUntilVisible(
      h.feature(IntegrationFeature.lastFmSameVibes),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Same Vibes mixes'), findsOneWidget);
    expect(
      find.text(
        'On: Instant Mix finds similar songs through Last.fm. Off: Instant '
        "Mix uses your server's mix.",
      ),
      findsOneWidget,
    );
    expect(
      find.text('Synced lyrics from LRCLIB first, server lyrics as fallback.'),
      findsOneWidget,
    );
  });

  testWidgets('master off locks every service and feature with the reason', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      seed: (dao) async {
        await dao.updateListenBrainzScrobblingState(
          enabled: true,
          tokenValid: true,
        );
        await dao.setExternalIntegrationsEnabled(enabled: false);
      },
    );

    final master = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('integrations-master')),
    );
    expect(master.value, isFalse);
    expect(master.onChanged, isNotNull);
    for (final feature in IntegrationFeature.values) {
      final tile = h.featureTile(feature);
      expect(tile.onChanged, isNull, reason: feature.key);
      // The choice that returns when Online services are back on.
      expect(tile.value, isTrue, reason: feature.key);
      expect(
        (tile.subtitle! as Text).data,
        'Online services are off.',
        reason: feature.key,
      );
    }
    for (final service in IntegrationService.values) {
      expect(h.serviceSwitch(service).onChanged, isNull, reason: service.key);
    }
  });

  testWidgets('master off without a ListenBrainz token reads it as off', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      seed: (dao) => dao.setExternalIntegrationsEnabled(enabled: false),
    );

    expect(h.serviceSwitch(IntegrationService.listenBrainz).value, isFalse);
    for (final feature in IntegrationFeature.forService(
      IntegrationService.listenBrainz,
    )) {
      final tile = h.featureTile(feature);
      expect(tile.value, isFalse, reason: feature.key);
      expect(tile.onChanged, isNull, reason: feature.key);
      // The master lock outranks the missing token in the reason.
      expect((tile.subtitle! as Text).data, 'Online services are off.');
    }
    // Verified services still show the choice that comes back.
    expect(h.featureTile(IntegrationFeature.lrclibLyrics).value, isTrue);
  });

  testWidgets('master off in a keyless build without a key reads Last.fm off', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      lastFmBundled: false,
      lastFmApiKey: '',
      seed: (dao) => dao.setExternalIntegrationsEnabled(enabled: false),
    );

    expect(h.serviceSwitch(IntegrationService.lastFm).value, isFalse);
    for (final feature in IntegrationFeature.forService(
      IntegrationService.lastFm,
    )) {
      final tile = h.featureTile(feature);
      expect(tile.value, isFalse, reason: feature.key);
      expect(tile.onChanged, isNull, reason: feature.key);
      expect((tile.subtitle! as Text).data, 'Online services are off.');
    }
  });

  testWidgets('a switched-off service locks its features', (tester) async {
    final h = await _pump(
      tester,
      seed: (dao) => dao.setIntegrationEnabled('deezer', enabled: false),
    );

    expect(h.serviceSwitch(IntegrationService.deezer).value, isFalse);
    expect(h.serviceSwitch(IntegrationService.deezer).onChanged, isNotNull);
    for (final feature in IntegrationFeature.forService(
      IntegrationService.deezer,
    )) {
      final tile = h.featureTile(feature);
      expect(tile.onChanged, isNull);
      expect((tile.subtitle! as Text).data, 'Deezer is off.');
    }
    expect(h.featureTile(IntegrationFeature.lrclibLyrics).onChanged, isNotNull);
  });

  testWidgets('unverified ListenBrainz rows are locked until the token works', (
    tester,
  ) async {
    final h = await _pump(tester);

    expect(h.serviceSwitch(IntegrationService.listenBrainz).value, isFalse);
    expect(h.serviceSwitch(IntegrationService.listenBrainz).onChanged, isNull);
    for (final feature in IntegrationFeature.forService(
      IntegrationService.listenBrainz,
    )) {
      final tile = h.featureTile(feature);
      expect(tile.value, isFalse, reason: feature.key);
      expect(tile.onChanged, isNull, reason: feature.key);
      expect(
        (tile.subtitle! as Text).data,
        'Needs a verified ListenBrainz token.',
      );
    }
  });

  testWidgets('a keyless build shows the key field and locks Last.fm', (
    tester,
  ) async {
    final h = await _pump(tester, lastFmBundled: false, lastFmApiKey: '');

    await tester.scrollUntilVisible(
      _textFieldWithLabel('API Key'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(_textFieldWithLabel('API Key'), findsOneWidget);
    expect(find.text('Key included with this build'), findsNothing);
    expect(h.serviceSwitch(IntegrationService.lastFm).onChanged, isNull);
    for (final feature in IntegrationFeature.forService(
      IntegrationService.lastFm,
    )) {
      final tile = h.featureTile(feature);
      expect(tile.value, isFalse, reason: feature.key);
      expect(tile.onChanged, isNull, reason: feature.key);
      expect(
        (tile.subtitle! as Text).data,
        'Needs a verified Last.fm API key.',
      );
    }
  });

  testWidgets('a rejected Last.fm key shows the field error and is not saved', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      lastFmBundled: false,
      lastFmApiKey: '',
      lastFmClientFactory: (_) => _FakeLastFmApiClient(
        const LastFmApiKeyValidationResult(
          valid: false,
          apiErrorCode: 10,
          message: 'Invalid API key',
        ),
      ),
    );

    await tester.scrollUntilVisible(
      _textFieldWithLabel('API Key'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(_textFieldWithLabel('API Key'), 'bad-key');
    await h.tap(find.widgetWithText(FilledButton, 'Save'));

    expect(find.text('Invalid Last.fm API key.'), findsOneWidget);
    expect((await h.row()).lastFmApiKey, isNull);
  });

  testWidgets('a valid Last.fm key is saved', (tester) async {
    final h = await _pump(
      tester,
      lastFmBundled: false,
      lastFmApiKey: '',
      lastFmClientFactory: (_) =>
          _FakeLastFmApiClient(const LastFmApiKeyValidationResult(valid: true)),
    );

    await tester.scrollUntilVisible(
      _textFieldWithLabel('API Key'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(_textFieldWithLabel('API Key'), 'good-key');
    await h.tap(find.widgetWithText(FilledButton, 'Save'));

    expect((await h.row()).lastFmApiKey, 'good-key');
  });

  testWidgets('toggles write at once through the integration writers', (
    tester,
  ) async {
    final h = await _pump(tester);

    await h.tap(h.feature(IntegrationFeature.deezerTopSongs));
    expect(parseDisabledIntegrationKeys((await h.row()).disabledIntegrations), {
      'deezer.topSongs',
    });
    expect(h.featureTile(IntegrationFeature.deezerTopSongs).value, isFalse);

    await h.tap(h.feature(IntegrationFeature.lrclibLyrics));
    expect((await h.row()).useLrclib, isFalse);

    await h.tap(h.service(IntegrationService.serverLinkedArtwork));
    expect(parseDisabledIntegrationKeys((await h.row()).disabledIntegrations), {
      'deezer.topSongs',
      'artwork',
    });

    await h.tap(find.byKey(const ValueKey<String>('integrations-master')));
    expect((await h.row()).externalIntegrationsEnabled, isFalse);
    expect(
      h.featureTile(IntegrationFeature.lastFmRadio).onChanged,
      isNull,
      reason: 'the page follows the stored master switch',
    );
  });

  testWidgets('the Same Vibes switch is the Instant Mix mode', (tester) async {
    final h = await _pump(tester);
    expect(
      h.container.read(preferredMixModeProvider),
      PreferredMixMode.sameVibes,
    );

    await h.tap(h.feature(IntegrationFeature.lastFmSameVibes));

    // Stored inverted: Same Vibes off is legacyInstantMixEnabled on.
    expect((await h.row()).legacyInstantMixEnabled, isTrue);
    expect(
      h.container.read(preferredMixModeProvider),
      PreferredMixMode.legacyInstantMix,
    );
  });

  testWidgets('validating a ListenBrainz token saves it and unlocks features', (
    tester,
  ) async {
    final store = _MemoryCredentialStore();
    final client = _FakeListenBrainzApiClient(valid: true);
    final h = await _pump(
      tester,
      credentialStore: store,
      listenBrainzClient: client,
    );

    await tester.scrollUntilVisible(
      _textFieldWithLabel('User Token'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(_textFieldWithLabel('User Token'), 'token-1');
    await h.tap(find.widgetWithText(FilledButton, 'Validate and save'));

    expect(client.userInitiatedCalls, <bool>[true]);
    expect(store.listenBrainzToken, 'token-1');
    final row = await h.row();
    expect(row.listenBrainzTokenValid, isTrue);
    expect(row.listenBrainzScrobblingEnabled, isTrue);
    expect(row.listenBrainzUserName, 'navis-user');
    expect(find.text('Connected as navis-user.'), findsOneWidget);
    expect(
      h.featureTile(IntegrationFeature.listenBrainzFeedback).onChanged,
      isNotNull,
    );
  });

  testWidgets('checking a connected token again keeps scrobbling off', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      seed: (dao) => dao.updateListenBrainzScrobblingState(
        enabled: false,
        tokenValid: true,
        userName: 'navis-user',
      ),
      credentialStore: _MemoryCredentialStore('token-1'),
      listenBrainzClient: _FakeListenBrainzApiClient(valid: true),
    );

    await h.tap(find.widgetWithText(TextButton, 'Update'));

    final row = await h.row();
    expect(row.listenBrainzTokenValid, isTrue);
    expect(row.listenBrainzScrobblingEnabled, isFalse);
  });

  testWidgets('a rejected ListenBrainz token shows the error on the field', (
    tester,
  ) async {
    final store = _MemoryCredentialStore();
    final h = await _pump(
      tester,
      credentialStore: store,
      listenBrainzClient: _FakeListenBrainzApiClient(valid: false),
    );

    await tester.scrollUntilVisible(
      _textFieldWithLabel('User Token'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(_textFieldWithLabel('User Token'), 'bad');
    await h.tap(find.widgetWithText(FilledButton, 'Validate and save'));

    expect(find.text('Invalid ListenBrainz token.'), findsOneWidget);
    expect(store.listenBrainzToken, isNull);
    expect((await h.row()).listenBrainzTokenValid, isFalse);
  });

  testWidgets('hides update checks where Navis cannot update itself', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final h = await _pump(tester);
      expect(h.service(IntegrationService.updates), findsNothing);
      expect(h.feature(IntegrationFeature.updatesAutomatic), findsNothing);
      expect(h.service(IntegrationService.autoEq), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  group('golden', () {
    Future<void> seedVerified(AppSettingsDao dao) =>
        dao.updateListenBrainzScrobblingState(
          enabled: true,
          tokenValid: true,
          userName: 'navis-user',
        );

    testWidgets('phone', (tester) async {
      await _pump(
        tester,
        seed: seedVerified,
        size: const Size(390, 844),
        theme: testTheme(buildLightTheme(defaultColorSchemeSeedColor)),
      );
      await expectLater(
        find.byType(IntegrationsSettingsScreen),
        matchesGoldenFile('goldens/integrations_settings_phone.png'),
      );
    });

    testWidgets('desktop', (tester) async {
      await _pump(
        tester,
        seed: seedVerified,
        size: const Size(1280, 800),
        desktop: true,
        theme: testTheme(buildDarkTheme(defaultColorSchemeSeedColor)),
      );
      await expectLater(
        find.byType(IntegrationsSettingsScreen),
        matchesGoldenFile('goldens/integrations_settings_desktop.png'),
      );
    });
  });
}
