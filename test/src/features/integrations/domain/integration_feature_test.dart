import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

IntegrationPolicy _policy({
  bool master = true,
  String? disabledJson = '[]',
  bool useLrclib = true,
  bool updateCheckEnabled = true,
  bool listenBrainzScrobblingEnabled = true,
  bool legacyInstantMixEnabled = false,
  bool lastFmVerified = true,
  bool listenBrainzVerified = true,
}) => IntegrationPolicy.resolve(
  masterEnabled: master,
  disabledJson: disabledJson,
  useLrclib: useLrclib,
  updateCheckEnabled: updateCheckEnabled,
  listenBrainzScrobblingEnabled: listenBrainzScrobblingEnabled,
  legacyInstantMixEnabled: legacyInstantMixEnabled,
  lastFmVerified: lastFmVerified,
  listenBrainzVerified: listenBrainzVerified,
);

void main() {
  group('integration keys', () {
    test('every feature key is unique, prefixed by its service key', () {
      final keys = IntegrationFeature.values.map((f) => f.key).toList();
      expect(keys.toSet().length, keys.length);
      for (final feature in IntegrationFeature.values) {
        expect(feature.key, startsWith('${feature.service.key}.'));
        expect(IntegrationFeature.tryParse(feature.key), feature);
      }
      expect(IntegrationService.values.map((s) => s.key), <String>[
        'deezer',
        'lastfm',
        'listenbrainz',
        'lrclib',
        'updates',
        'autoeq',
        'radio',
        'artwork',
      ]);
    });

    test('the planned feature keys exist exactly', () {
      expect(IntegrationFeature.values.map((f) => f.key).toSet(), <String>{
        'deezer.topSongs',
        'deezer.artistImages',
        'deezer.similarArtists',
        'deezer.missingAlbums',
        'deezer.newReleases',
        'deezer.trending',
        'lastfm.sameVibes',
        'lastfm.radio',
        'lastfm.topSongs',
        'listenbrainz.scrobbling',
        'listenbrainz.feedback',
        'listenbrainz.weeklyPlaylists',
        'lrclib.lyrics',
        'updates.automatic',
        'autoeq.catalogue',
        'radio.nowPlaying',
        'artwork.serverLinked',
      });
    });

    test('only the four legacy-column features are column-backed', () {
      final backed = {
        for (final f in IntegrationFeature.values)
          if (f.legacyColumn != null) f.key: f.legacyColumn,
      };
      expect(backed, <String, IntegrationLegacyColumn>{
        'lrclib.lyrics': IntegrationLegacyColumn.useLrclib,
        'updates.automatic': IntegrationLegacyColumn.updateCheckEnabled,
        'listenbrainz.scrobbling':
            IntegrationLegacyColumn.listenBrainzScrobblingEnabled,
        'lastfm.sameVibes': IntegrationLegacyColumn.legacyInstantMixEnabled,
      });
      expect(
        IntegrationLegacyColumn.legacyInstantMixEnabled.featureEnabledFor(
          columnValue: true,
        ),
        isFalse,
      );
      expect(
        IntegrationLegacyColumn.legacyInstantMixEnabled.columnValueFor(
          featureEnabled: true,
        ),
        isFalse,
      );
      expect(
        IntegrationLegacyColumn.useLrclib.featureEnabledFor(columnValue: true),
        isTrue,
      );
    });

    test('isIntegrationKey allows service and feature keys only', () {
      expect(isIntegrationKey('deezer'), isTrue);
      expect(isIntegrationKey('deezer.topSongs'), isTrue);
      expect(isIntegrationKey('Deezer'), isFalse);
      expect(isIntegrationKey('deezer.nope'), isFalse);
      expect(isIntegrationKey(''), isFalse);
    });

    test('parseDisabledIntegrationKeys keeps only JSON-stored known keys', () {
      expect(parseDisabledIntegrationKeys(null), isEmpty);
      expect(parseDisabledIntegrationKeys(''), isEmpty);
      expect(parseDisabledIntegrationKeys('not json'), isEmpty);
      expect(parseDisabledIntegrationKeys('{"a":1}'), isEmpty);
      expect(
        parseDisabledIntegrationKeys(
          '["deezer","deezer.topSongs","lrclib.lyrics","bogus",7]',
        ),
        <String>{'deezer', 'deezer.topSongs'},
      );
      expect(
        encodeDisabledIntegrationKeys(<String>['b', 'a', 'a']),
        '["a","b"]',
      );
    });
  });

  group('IntegrationPolicy.allows', () {
    test('everything verified is allowed by default', () {
      final policy = _policy();
      for (final feature in IntegrationFeature.values) {
        expect(policy.allows(feature), isTrue, reason: feature.key);
        expect(policy.isUserToggleable(feature), isTrue, reason: feature.key);
        expect(policy.lockReason(feature), isNull, reason: feature.key);
      }
    });

    test('master off denies and locks every feature', () {
      final policy = _policy(master: false);
      for (final feature in IntegrationFeature.values) {
        expect(policy.allows(feature), isFalse, reason: feature.key);
        expect(policy.isUserToggleable(feature), isFalse, reason: feature.key);
        expect(
          policy.lockReason(feature),
          IntegrationLockReason.masterOff,
          reason: feature.key,
        );
      }
      for (final service in IntegrationService.values) {
        expect(policy.isServiceEnabled(service), isFalse);
        expect(policy.isServiceSwitchOn(service), isTrue);
      }
    });

    test('service off denies its features only', () {
      final policy = _policy(disabledJson: '["deezer"]');
      for (final feature in IntegrationFeature.values) {
        final isDeezer = feature.service == IntegrationService.deezer;
        expect(policy.allows(feature), !isDeezer, reason: feature.key);
        expect(
          policy.lockReason(feature),
          isDeezer ? IntegrationLockReason.serviceOff : isNull,
          reason: feature.key,
        );
      }
    });

    test('a feature off denies that feature only', () {
      final policy = _policy(disabledJson: '["deezer.topSongs"]');
      expect(policy.allows(IntegrationFeature.deezerTopSongs), isFalse);
      expect(policy.allows(IntegrationFeature.deezerTrending), isTrue);
      // The user can switch it back on.
      expect(
        policy.isUserToggleable(IntegrationFeature.deezerTopSongs),
        isTrue,
      );
    });

    test('legacy columns are the switches for their features', () {
      final policy = _policy(
        useLrclib: false,
        updateCheckEnabled: false,
        listenBrainzScrobblingEnabled: false,
        legacyInstantMixEnabled: true,
      );
      expect(policy.allows(IntegrationFeature.lrclibLyrics), isFalse);
      expect(policy.allows(IntegrationFeature.updatesAutomatic), isFalse);
      expect(policy.allows(IntegrationFeature.listenBrainzScrobbling), isFalse);
      // legacyInstantMixEnabled is inverted: true means Same Vibes is off.
      expect(policy.allows(IntegrationFeature.lastFmSameVibes), isFalse);
      // Other features of those services are untouched.
      expect(policy.allows(IntegrationFeature.lastFmRadio), isTrue);
      expect(policy.allows(IntegrationFeature.listenBrainzFeedback), isTrue);

      final on = _policy(legacyInstantMixEnabled: false);
      expect(on.allows(IntegrationFeature.lastFmSameVibes), isTrue);
    });

    test('a column-backed key in the JSON set is ignored', () {
      final policy = _policy(disabledJson: '["lrclib.lyrics"]');
      expect(policy.allows(IntegrationFeature.lrclibLyrics), isTrue);
    });

    test('unverified Last.fm denies and locks its features as notVerified', () {
      final policy = _policy(lastFmVerified: false);
      for (final feature in IntegrationFeature.forService(
        IntegrationService.lastFm,
      )) {
        expect(policy.allows(feature), isFalse, reason: feature.key);
        expect(policy.isUserToggleable(feature), isFalse, reason: feature.key);
        expect(
          policy.lockReason(feature),
          IntegrationLockReason.notVerified,
          reason: feature.key,
        );
      }
      expect(policy.allows(IntegrationFeature.deezerTopSongs), isTrue);
      expect(
        policy.serviceLockReason(IntegrationService.lastFm),
        IntegrationLockReason.notVerified,
      );
    });

    test('unverified ListenBrainz denies and locks its features', () {
      final policy = _policy(listenBrainzVerified: false);
      for (final feature in IntegrationFeature.forService(
        IntegrationService.listenBrainz,
      )) {
        expect(policy.allows(feature), isFalse, reason: feature.key);
        expect(
          policy.lockReason(feature),
          IntegrationLockReason.notVerified,
          reason: feature.key,
        );
        // Enabled by the user's switches, only the credential is missing.
        expect(policy.isEnabled(feature), isTrue, reason: feature.key);
      }
    });

    test('lock reasons rank master over service over credential', () {
      final policy = _policy(
        master: false,
        disabledJson: '["lastfm"]',
        lastFmVerified: false,
      );
      expect(
        policy.lockReason(IntegrationFeature.lastFmRadio),
        IntegrationLockReason.masterOff,
      );
      final serviceOff = _policy(
        disabledJson: '["lastfm"]',
        lastFmVerified: false,
      );
      expect(
        serviceOff.lockReason(IntegrationFeature.lastFmRadio),
        IntegrationLockReason.serviceOff,
      );
    });

    test('services without a credential are always verified', () {
      final policy = _policy(
        lastFmVerified: false,
        listenBrainzVerified: false,
      );
      for (final service in IntegrationService.values) {
        final needsCredential =
            service.verification != IntegrationVerification.none;
        expect(
          policy.isVerified(service),
          !needsCredential,
          reason: service.key,
        );
      }
    });

    test('denyAll denies every feature', () {
      const policy = IntegrationPolicy.denyAll();
      for (final feature in IntegrationFeature.values) {
        expect(policy.allows(feature), isFalse, reason: feature.key);
        expect(policy.isUserToggleable(feature), isFalse, reason: feature.key);
      }
    });
  });

  group('IntegrationPolicy equality', () {
    test('equal inputs are equal regardless of JSON order', () {
      final a = _policy(disabledJson: '["deezer","autoeq.catalogue"]');
      final b = _policy(disabledJson: '["autoeq.catalogue","deezer"]');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('any differing input is unequal', () {
      final base = _policy();
      expect(base, isNot(_policy(master: false)));
      expect(base, isNot(_policy(disabledJson: '["deezer"]')));
      expect(base, isNot(_policy(useLrclib: false)));
      expect(base, isNot(_policy(lastFmVerified: false)));
      expect(base, isNot(_policy(listenBrainzVerified: false)));
    });
  });
}
