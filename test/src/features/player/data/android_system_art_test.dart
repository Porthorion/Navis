import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/android_system_art.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';

Uri _cover(String id) => Uri.parse(
  'https://music.test/rest/getCoverArt.view?id=$id&u=me&t=tok&s=salt&size=512',
);

class _Fetches {
  final List<String> ids = <String>[];
  Completer<String?>? hold;

  Future<String?> call(String coverArtId, Uri artUri) {
    ids.add(coverArtId);
    return hold?.future ?? Future<String?>.value('/cache/$coverArtId.jpg');
  }
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
  test('replaces a credential-bearing cover URL with a content URI', () {
    final fetches = _Fetches();
    final art = AndroidSystemArt(authority: 'app.test.artwork', fetch: fetches);

    final mapped = art.forSystem(
      MediaItem(id: 's', title: 't', artUri: _cover('al-1/x')),
      prefetch: true,
    );

    expect(mapped.artUri.toString(), 'content://app.test.artwork/cover/al-1_x');
    expect(mapped.artUri.toString(), isNot(contains('tok')));
    expect(fetches.ids, <String>['al-1/x']);
  });

  test('passes radio art through and drops unusable cover URLs', () {
    final art = AndroidSystemArt(
      authority: 'a.artwork',
      fetch: _Fetches().call,
    );
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

  test('browse lists wait for their covers, but not past the budget', () async {
    final fetches = _Fetches()..hold = Completer<String?>();
    final art = AndroidSystemArt(authority: 'a.artwork', fetch: fetches.call);
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
    expect(mapped.map((item) => item.artUri?.scheme), everyElement('content'));
    fetches.hold!.complete(null);
  });

  test('the projection publishes only content URIs for covers', () async {
    final fetches = _Fetches();
    final inner = _InnerHandler()
      ..children = <MediaItem>[
        MediaItem(id: 'album', title: 'Album', artUri: _cover('c-2')),
      ];
    final projection = RealTimeProjectionAudioHandler(
      inner,
      systemArt: AndroidSystemArt(authority: 'a.artwork', fetch: fetches.call),
    );
    final song = MediaItem(id: 'song', title: 'Song', artUri: _cover('c-1'));
    inner.mediaItem.add(song);
    inner.queue.add(<MediaItem>[song]);
    inner.playbackState.add(PlaybackState(queueIndex: 0));
    await pumpEventQueue();

    expect(projection.mediaItem.value!.artUri!.scheme, 'content');
    expect(projection.queue.value.single.artUri!.scheme, 'content');
    final children = await projection.getChildren('root');
    expect(children.single.artUri.toString(), 'content://a.artwork/cover/c-2');
    // The app keeps its own cover URL.
    expect(inner.mediaItem.value!.artUri, _cover('c-1'));
  });
}
