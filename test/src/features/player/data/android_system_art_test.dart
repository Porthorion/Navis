import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/android_system_art.dart';
import 'package:navis/src/features/player/data/playback_art_cache.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';

Uri _cover(String id) => Uri.parse(
  'https://music.test/rest/getCoverArt.view?id=$id&u=me&t=tok&s=salt&size=512',
);

/// Stands in for `PlaybackArtCache`: a cover is cached once its fetch
/// completes with a path, and [held] covers stay pending until completed.
class _Fetches {
  final List<String> ids = <String>[];
  final Map<String, String> cached = <String, String>{};
  final Map<String, Completer<String?>> held = <String, Completer<String?>>{};

  Future<String?> call(String coverArtId, Uri artUri) async {
    ids.add(coverArtId);
    final path =
        await (held[coverArtId]?.future ??
            Future<String?>.value('/cache/$coverArtId.jpg'));
    if (path != null) cached[coverArtId] = path;
    return path;
  }

  String? lookup(String coverArtId) => cached[coverArtId];

  AndroidSystemArt art([String authority = 'a.artwork']) =>
      AndroidSystemArt(authority: authority, fetch: call, cachedPath: lookup);
}

class _InnerHandler extends BaseAudioHandler {
  List<MediaItem> children = const <MediaItem>[];

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async => children;
}

void main() {
  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-system-art-key-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await PlaybackArtCache.initializeKey(supportDirectory: directory);
  });
  test('publishes no cover until it is cached, then a content URI', () async {
    final fetches = _Fetches()..held['al-1/x'] = Completer<String?>();
    final art = fetches.art('app.test.artwork');
    final song = MediaItem(id: 's', title: 't', artUri: _cover('al-1/x'));

    // A content URI the provider cannot open yet would leave the session
    // with empty art that Bluetooth and Android Auto never refresh.
    expect(art.forSystem(song, prefetch: true).artUri, isNull);
    expect(fetches.ids, <String>['al-1/x']);

    fetches.held['al-1/x']!.complete('/cache/al-1_x.jpg');
    await pumpEventQueue();

    final mapped = art.forSystem(song);
    expect(
      mapped.artUri.toString(),
      'content://app.test.artwork/cover/${PlaybackArtCache.fileKey('al-1/x')}',
    );
    expect(mapped.artUri.toString(), isNot(contains('tok')));
  });

  test('a cover already handed to the session counts as cached', () {
    final fetches = _Fetches();
    final art = fetches.art();

    final mapped = art.forSystem(
      MediaItem(
        id: 's',
        title: 't',
        artUri: _cover('c-9'),
        extras: const <String, dynamic>{'artCacheFile': '/cache/c-9.jpg'},
      ),
    );

    expect(
      mapped.artUri.toString(),
      'content://a.artwork/cover/${PlaybackArtCache.fileKey('c-9')}',
    );
    expect(fetches.ids, isEmpty);
  });

  test('a cache hit hands the session the file with the content URI', () {
    // Without artCacheFile audio_service puts empty ALBUM_ART into the
    // session for a content URI, and Bluetooth then ignores the real bitmap.
    final fetches = _Fetches()..cached['c-3'] = '/cache/c-3.jpg';
    final art = fetches.art();

    final mapped = art.forSystem(
      MediaItem(id: 's', title: 't', artUri: _cover('c-3')),
    );

    expect(mapped.artUri?.scheme, 'content');
    expect(mapped.extras?['artCacheFile'], '/cache/c-3.jpg');
    // No cache hit: no URI at all.
    expect(
      art
          .forSystem(MediaItem(id: 's', title: 't', artUri: _cover('c-4')))
          .artUri,
      isNull,
    );
  });

  test(
    'the projection never publishes a content URI without the file',
    () async {
      final fetches = _Fetches()..cached['c-5'] = '/cache/c-5.jpg';
      final inner = _InnerHandler();
      final projection = RealTimeProjectionAudioHandler(
        inner,
        systemArt: fetches.art(),
      );
      inner.mediaItem.add(
        MediaItem(
          id: 'song',
          title: 'Song',
          artUri: _cover('c-5'),
          extras: const <String, dynamic>{'coverArtId': 'c-5'},
        ),
      );
      await pumpEventQueue();

      final published = projection.mediaItem.value!;
      expect(published.artUri?.scheme, 'content');
      expect(published.extras?['artCacheFile'], '/cache/c-5.jpg');
    },
  );

  test('passes radio art through and drops unusable cover URLs', () {
    final art = _Fetches().art();
    final radio = Uri.parse('https://radio.test/now.jpg');

    expect(
      art.forSystem(MediaItem(id: 'r', title: 'r', artUri: radio)).artUri,
      radio,
    );
    expect(
      art
          .forSystem(
            MediaItem(
              id: 's',
              title: 't',
              artUri: Uri.parse('https://h.test/rest/x?u=me&t=tok'),
            ),
          )
          .artUri,
      isNull,
    );
  });

  test(
    'radio art stays http(s) and a private file URI is never published',
    () async {
      final art = _Fetches().art();
      final radio = Uri.parse('http://radio.test/now.jpg');

      final published = art.forSystem(
        MediaItem(id: 'r', title: 'r', artUri: radio),
      );
      expect(published.artUri, radio);
      expect(published.artUri!.scheme, anyOf('http', 'https'));

      // Android Auto runs in another process and cannot open an app-private
      // file, so such a URI is dropped rather than handed to the session.
      final privateFile = MediaItem(
        id: 'r',
        title: 'r',
        artUri: Uri.file('/data/user/0/app/cache/cover.jpg'),
      );
      expect(art.forSystem(privateFile).artUri, isNull);
      final listed = await art.forSystemList(<MediaItem>[privateFile]);
      expect(listed.single.artUri, isNull);
    },
  );

  test('browse lists wait for their covers, but not past the budget', () async {
    final fetches = _Fetches()..held['b'] = Completer<String?>();
    final art = fetches.art();
    final items = <MediaItem>[
      for (final id in <String>['a', 'b', 'a'])
        MediaItem(id: id, title: id, artUri: _cover(id)),
    ];

    final watch = Stopwatch()..start();
    final mapped = await art.forSystemList(
      items,
      budget: const Duration(milliseconds: 100),
    );

    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(fetches.ids, <String>['a', 'b']);
    // Only covers that are on disk are offered; the rest appear the next
    // time the list is shown.
    expect(mapped.map((item) => item.artUri?.toString()), <String?>[
      'content://a.artwork/cover/${PlaybackArtCache.fileKey('a')}',
      null,
      'content://a.artwork/cover/${PlaybackArtCache.fileKey('a')}',
    ]);
    fetches.held['b']!.complete(null);
  });

  test('the projection publishes cover art only once it is cached', () async {
    final fetches = _Fetches()..held['c-1'] = Completer<String?>();
    final inner = _InnerHandler()
      ..children = <MediaItem>[
        MediaItem(id: 'album', title: 'Album', artUri: _cover('c-2')),
      ];
    final projection = RealTimeProjectionAudioHandler(
      inner,
      systemArt: fetches.art(),
    );
    final song = MediaItem(
      id: 'song',
      title: 'Song',
      artUri: _cover('c-1'),
      extras: const <String, dynamic>{'coverArtId': 'c-1'},
    );
    inner.mediaItem.add(song);
    inner.queue.add(<MediaItem>[song]);
    inner.playbackState.add(PlaybackState(queueIndex: 0));
    await pumpEventQueue();

    expect(projection.mediaItem.value!.artUri, isNull);
    expect(projection.queue.value.single.artUri, isNull);
    expect(fetches.ids, contains('c-1'));

    // NavisAudioHandler re-emits the song with its cache file once the
    // download completes.
    fetches.held['c-1']!.complete('/cache/c-1.jpg');
    await pumpEventQueue();
    final withArt = song.copyWith(
      extras: <String, dynamic>{
        ...?song.extras,
        'artCacheFile': '/cache/c-1.jpg',
      },
    );
    inner.mediaItem.add(withArt);
    inner.queue.add(<MediaItem>[withArt]);
    await pumpEventQueue();

    expect(
      projection.mediaItem.value!.artUri.toString(),
      'content://a.artwork/cover/${PlaybackArtCache.fileKey('c-1')}',
    );
    expect(projection.queue.value.single.artUri!.scheme, 'content');
    final children = await projection.getChildren('root');
    expect(
      children.single.artUri.toString(),
      'content://a.artwork/cover/${PlaybackArtCache.fileKey('c-2')}',
    );
    // The app keeps its own cover URL.
    expect(inner.mediaItem.value!.artUri, _cover('c-1'));
  });
}
