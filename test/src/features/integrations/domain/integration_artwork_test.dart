import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

void main() {
  const server = 'music.example.org';

  IntegrationFeature? map(String url, {String? serverHost = server}) =>
      integrationFeatureForArtworkUri(Uri.parse(url), serverHost: serverHost);

  test(
    'radio artwork needs both radio metadata and the mapped host service',
    () {
      final uri = Uri.parse('https://cdn.dzcdn.net/cover');
      for (final disabled in [
        <String>{'radio.nowPlaying'},
        <String>{'deezer'},
        <String>{'artwork'},
      ]) {
        final image = disabled.contains('artwork')
            ? Uri.parse('https://other.example/cover')
            : uri;
        expect(
          integrationAllowsRadioArtworkUri(
            IntegrationPolicy(disabledKeys: disabled),
            image,
            serverHost: server,
          ),
          isFalse,
        );
      }
      expect(
        integrationAllowsRadioArtworkUri(
          const IntegrationPolicy(masterEnabled: false),
          uri,
          serverHost: server,
        ),
        isFalse,
      );
      expect(
        integrationAllowsRadioArtworkUri(
          const IntegrationPolicy(),
          uri,
          serverHost: server,
        ),
        isTrue,
      );
    },
  );

  test('own-server radio art is allowed with master or radio switches off', () {
    for (final policy in [
      const IntegrationPolicy(masterEnabled: false),
      const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'}),
      const IntegrationPolicy(disabledKeys: {'radio'}),
      const IntegrationPolicy.denyAll(),
    ]) {
      expect(
        integrationAllowsRadioArtworkUri(
          policy,
          Uri.parse('https://MUSIC.example.org:4533/cover.jpg'),
          serverHost: server,
        ),
        isTrue,
      );
    }
  });

  group('integrationFeatureForArtworkUri', () {
    test('the user server host is always allowed', () {
      expect(
        map('https://music.example.org/rest/getCoverArt.view?id=al-1'),
        isNull,
      );
      expect(map('https://MUSIC.example.org:4533/cover.jpg'), isNull);
    });

    test('Deezer image hosts map to Deezer artist images', () {
      expect(
        map('https://e-cdns-images.dzcdn.net/images/artist/a/500x500.jpg'),
        IntegrationFeature.deezerArtistImages,
      );
      expect(
        map('https://cdn-images.dzcdn.net/x.jpg'),
        IntegrationFeature.deezerArtistImages,
      );
      expect(
        map('https://api.deezer.com/artist/1/image'),
        IntegrationFeature.deezerArtistImages,
      );
    });

    test('Last.fm hosts map to server-linked artwork', () {
      for (final url in [
        'https://lastfm.freetls.fastly.net/i/u/300x300/x.png',
        'https://www.last.fm/music/Artist/+images/1',
        'https://ws.audioscrobbler.com/x.jpg',
      ]) {
        expect(map(url), IntegrationFeature.artworkServerLinked, reason: url);
      }
    });

    test('ListenBrainz and Cover Art Archive map to weekly playlists', () {
      expect(
        map('https://listenbrainz.org/static/img/cover.png'),
        IntegrationFeature.listenBrainzWeeklyPlaylists,
      );
      expect(
        map('https://coverartarchive.org/release/abc/front-500'),
        IntegrationFeature.listenBrainzWeeklyPlaylists,
      );
      expect(
        map('https://ia800000.us.archive.org/coverartarchive.org/x.jpg'),
        IntegrationFeature.artworkServerLinked,
        reason: 'only the coverartarchive.org host itself matches',
      );
    });

    test('any other host maps to server-linked artwork', () {
      expect(
        map('https://images.example.com/a.jpg'),
        IntegrationFeature.artworkServerLinked,
      );
      expect(
        map('https://notdeezer.com/a.jpg'),
        IntegrationFeature.artworkServerLinked,
        reason: 'a suffix of the domain name is not a subdomain',
      );
    });

    test('without a known server every host is external', () {
      expect(
        map('https://music.example.org/cover.jpg', serverHost: null),
        IntegrationFeature.artworkServerLinked,
      );
    });

    test('a URL without a host maps to nothing', () {
      expect(map('/relative/path.jpg'), isNull);
    });
  });

  group('integrationAllowsArtworkUri', () {
    final externalUri = Uri.parse('https://images.example.com/a.jpg');

    test('server artwork loads even when everything is denied', () {
      expect(
        integrationAllowsArtworkUri(
          const IntegrationPolicy.denyAll(),
          Uri.parse('https://music.example.org/cover.jpg'),
          serverHost: server,
        ),
        isTrue,
      );
    });

    test('external artwork follows master and feature switches', () {
      const on = IntegrationPolicy();
      expect(
        integrationAllowsArtworkUri(on, externalUri, serverHost: server),
        isTrue,
      );
      expect(
        integrationAllowsArtworkUri(
          const IntegrationPolicy(masterEnabled: false),
          externalUri,
          serverHost: server,
        ),
        isFalse,
      );
      expect(
        integrationAllowsArtworkUri(
          const IntegrationPolicy(disabledKeys: {'artwork.serverLinked'}),
          externalUri,
          serverHost: server,
        ),
        isFalse,
      );
      expect(
        integrationAllowsArtworkUri(
          const IntegrationPolicy(disabledKeys: {'artwork'}),
          externalUri,
          serverHost: server,
        ),
        isFalse,
      );
    });

    test('artwork needs no credential, unlike the ListenBrainz feature', () {
      // ListenBrainz is unverified here, yet its cover art may load.
      expect(
        integrationAllowsArtworkUri(
          const IntegrationPolicy(),
          Uri.parse('https://coverartarchive.org/release/a/front'),
          serverHost: server,
        ),
        isTrue,
      );
    });

    test('an explicit feature overrides the host mapping', () {
      const radioOff = IntegrationPolicy(disabledKeys: {'radio.nowPlaying'});
      expect(
        integrationAllowsArtworkUri(
          radioOff,
          externalUri,
          serverHost: server,
          feature: IntegrationFeature.radioNowPlaying,
        ),
        isFalse,
      );
      expect(
        integrationAllowsArtworkUri(radioOff, externalUri, serverHost: server),
        isTrue,
      );
    });
  });

  group('integrationAllowsArtworkFeatureKey', () {
    final externalUri = Uri.parse('https://images.example.com/a.jpg');

    test('the named feature must be on, beyond the host service', () {
      const radioOff = IntegrationPolicy(disabledKeys: {'radio.nowPlaying'});
      expect(
        integrationAllowsArtworkFeatureKey(
          radioOff,
          externalUri,
          'radio.nowPlaying',
          serverHost: server,
        ),
        isFalse,
      );
      // The host's own service is still on, which is all the service-level
      // gate looks at.
      expect(
        integrationAllowsArtworkHost(radioOff, externalUri, serverHost: server),
        isTrue,
      );
      expect(
        integrationAllowsArtworkFeatureKey(
          const IntegrationPolicy(),
          externalUri,
          'radio.nowPlaying',
          serverHost: server,
        ),
        isTrue,
      );
    });

    test('the user server and unknown keys', () {
      expect(
        integrationAllowsArtworkFeatureKey(
          const IntegrationPolicy.denyAll(),
          Uri.parse('https://music.example.org/cover.jpg'),
          'radio.nowPlaying',
          serverHost: server,
        ),
        isTrue,
      );
      expect(
        integrationAllowsArtworkFeatureKey(
          const IntegrationPolicy(),
          externalUri,
          'not.a.feature',
          serverHost: server,
        ),
        isFalse,
      );
    });
  });

  group('integrationAllowsArtworkHost', () {
    test('checks the master and service switches only', () {
      final uri = Uri.parse('https://e-cdns-images.dzcdn.net/a.jpg');
      expect(
        integrationAllowsArtworkHost(
          const IntegrationPolicy(disabledKeys: {'deezer.artistImages'}),
          uri,
          serverHost: server,
        ),
        isTrue,
        reason: 'feature switches are the widget gate, not the loader gate',
      );
      expect(
        integrationAllowsArtworkHost(
          const IntegrationPolicy(disabledKeys: {'deezer'}),
          uri,
          serverHost: server,
        ),
        isFalse,
      );
      expect(
        integrationAllowsArtworkHost(
          const IntegrationPolicy(masterEnabled: false),
          uri,
          serverHost: server,
        ),
        isFalse,
      );
    });
  });
}
