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
  new(this.dir);

  final Directory dir;
  final List<String> ids = <String>[];
  final Map<String, String> cached = <String, String>{};
  final Map<String, Completer<String?>> held = <String, Completer<String?>>{};

  Future<String?> call(String coverArtId, Uri artUri) async {
    ids.add(coverArtId);
    final path =
        await (held[coverArtId]?.future ??
            Future<String?>.value(file('$coverArtId.jpg')));
    if (path != null) cached[coverArtId] = path;
    return path;
  }

  int lookups = 0;

  String? lookup(String coverArtId) {
    lookups++;
    return cached[coverArtId];
  }

  /// A real JPEG-headed file: the system art checks the file before it
  /// publishes the content URI.
  String file(
    String name, {
    List<int> bytes = const <int>[0xFF, 0xD8, 0xFF, 0],
  }) {
    final path = '${dir.path}/${name.replaceAll('/', '_')}';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

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
  late Directory covers;
  _Fetches newFetches() => _Fetches(covers);
  setUp(() async {
    covers = await Directory.systemTemp.createTemp('navis-system-art-');
    addTearDown(() => covers.delete(recursive: true));
  });
  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-system-art-key-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await PlaybackArtCache.initializeKey(supportDirectory: directory);
  });
  test('publishes no cover until it is cached, then a content URI', () async {
    final fetches = newFetches()..held['al-1/x'] = Completer<String?>();
    final art = fetches.art('app.test.artwork');
    final song = MediaItem(id: 's', title: 't', artUri: _cover('al-1/x'));

    // A content URI the provider cannot open yet would leave the session
    // with empty art that Bluetooth and Android Auto never refresh.
    expect(art.forSystem(song, prefetch: true).artUri, isNull);
    expect(fetches.ids, <String>['al-1/x']);

    fetches.held['al-1/x']!.complete(fetches.file('al-1_x.jpg'));
    await pumpEventQueue();

    final mapped = art.forSystem(song);
    expect(
      mapped.artUri.toString(),
      'content://app.test.artwork/cover/${PlaybackArtCache.fileKey('al-1/x')}',
    );
    expect(mapped.artUri.toString(), isNot(contains('tok')));
  });

  test('a cover already handed to the session counts as cached', () {
    final fetches = newFetches();
    final art = fetches.art();

    final mapped = art.forSystem(
      MediaItem(
        id: 's',
        title: 't',
        artUri: _cover('c-9'),
        extras: <String, dynamic>{'artCacheFile': fetches.file('c-9.jpg')},
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
    final fetches = newFetches();
    fetches.cached['c-3'] = fetches.file('c-3.jpg');
    final art = fetches.art();

    final mapped = art.forSystem(
      MediaItem(id: 's', title: 't', artUri: _cover('c-3')),
    );

    expect(mapped.artUri?.scheme, 'content');
    expect(mapped.extras?['artCacheFile'], fetches.cached['c-3']);
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
      final fetches = newFetches();
      fetches.cached['c-5'] = fetches.file('c-5.jpg');
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
      expect(published.extras?['artCacheFile'], fetches.cached['c-5']);
    },
  );

  test('passes radio art through and drops unusable cover URLs', () {
    final art = newFetches().art();
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
      final art = newFetches().art();
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
    final fetches = newFetches()..held['b'] = Completer<String?>();
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
    final fetches = newFetches()..held['c-1'] = Completer<String?>();
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
    final c1 = fetches.file('c-1.jpg');
    fetches.held['c-1']!.complete(c1);
    await pumpEventQueue();
    final withArt = song.copyWith(
      extras: <String, dynamic>{...?song.extras, 'artCacheFile': c1},
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

  test('withholds the content URI unless the file is an existing image', () {
    final fetches = newFetches();
    final art = fetches.art();
    MediaItem song(String id, {Object? file, bool extra = true}) => MediaItem(
      id: 's',
      title: 't',
      artUri: _cover(id),
      extras: extra ? <String, dynamic>{'artCacheFile': file} : null,
    );

    // A missing path, an empty string and a non-image file would make
    // audio_service put an empty bitmap into the session.
    for (final bad in <String>[
      '${covers.path}/gone.jpg',
      '',
      fetches.file('page.html', bytes: '<html>error</html>'.codeUnits),
      fetches.file('empty.jpg', bytes: const <int>[]),
    ]) {
      final mapped = art.forSystem(song('c-1', file: bad));
      expect(mapped.artUri, isNull, reason: 'file "$bad"');
      expect(mapped.extras?.containsKey('artCacheFile'), isFalse);
    }
    // The cache's own path gets the same check.
    fetches.cached['c-2'] = '${covers.path}/gone-too.jpg';
    expect(art.forSystem(song('c-2', extra: false)).artUri, isNull);

    final good = fetches.file('good.jpg');
    final mapped = art.forSystem(song('c-1', file: good));
    expect(mapped.artUri?.scheme, 'content');
    expect(mapped.extras?['artCacheFile'], good);
  });

  test(
    'a bad artCacheFile falls back to a good cached file, and refetches',
    () {
      final fetches = newFetches();
      final art = fetches.art();
      final good = fetches.file('c-7.jpg');
      fetches.cached['c-7'] = good;
      final mapped = art.forSystem(
        MediaItem(
          id: 's',
          title: 't',
          artUri: _cover('c-7'),
          extras: const <String, dynamic>{'artCacheFile': '/no/such/file.jpg'},
        ),
      );
      expect(mapped.artUri?.scheme, 'content');
      expect(mapped.extras?['artCacheFile'], good);

      art.forSystem(
        MediaItem(id: 's', title: 't', artUri: _cover('c-8')),
        prefetch: true,
      );
      expect(fetches.ids, <String>['c-8']);
    },
  );

  test('a list checks each cover once', () async {
    final fetches = newFetches();
    fetches.cached['c-1'] = fetches.file('c-1.jpg');
    final items = <MediaItem>[
      for (var i = 0; i < 5; i++)
        MediaItem(id: 's$i', title: 't', artUri: _cover('c-1')),
    ];

    final mapped = await fetches.art().forSystemList(items);

    expect(mapped.every((item) => item.artUri?.scheme == 'content'), isTrue);
    expect(fetches.lookups, 1);
  });

  test('the art downscale decodes 512 px covers at 256 px', () {
    // audio_service halves sampling only while the result stays >= this, so
    // the 512 px covers Navis fetches are halved (512 would leave them).
    expect(AndroidSystemArt.artDownscaleSize, 256);
  });
}
