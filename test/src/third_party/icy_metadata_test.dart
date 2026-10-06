import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/icy_metadata.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

class _Properties implements IcyPropertySource {
  final values = <String, String>{
    'path': 'https://stream.example.invalid/a',
    'metadata/by-key/icy-title': "Northcape - Doesn't Feel Like A Long Way",
    'metadata/by-key/icy-name': 'Station A',
    'metadata/by-key/icy-url': 'https://station.example.invalid',
    'media-title': 'fallback',
  };
  final listeners = <String, Future<void> Function(String)>{};
  final reads = <String>[];
  Completer<String>? delayedTitle;

  @override
  Future<String> read(String property) async {
    reads.add(property);
    if (property == 'metadata/by-key/icy-title' && delayedTitle != null) {
      return await delayedTitle!.future;
    }
    return values[property] ?? '';
  }

  @override
  Future<void> observe(
    String property,
    Future<void> Function(String) listener,
  ) async {
    listeners[property] = listener;
  }

  @override
  Future<void> unobserve(String property) async {
    listeners.remove(property);
  }

  Future<void> change(String property) async {
    await listeners[property]?.call('');
  }
}

void main() {
  late _Properties properties;
  late IcyMetadataObserver observer;
  late List<IcyMetadataMessage?> events;

  setUp(() async {
    properties = _Properties();
    events = [];
    observer = IcyMetadataObserver(source: properties, onChanged: events.add);
    observer.setSource(properties.values['path']);
    await observer.start();
  });
  tearDown(() => observer.dispose());

  test('native ICY title, URL and station name reach playback metadata', () {
    expect(
      observer.value?.info?.title,
      "Northcape - Doesn't Feel Like A Long Way",
    );
    expect(observer.value?.info?.url, 'https://station.example.invalid');
    expect(observer.value?.headers?.name, 'Station A');
    expect(observer.value?.headers?.genre, isNull);
    expect(properties.reads, isNot(contains('metadata/by-key/icy-genre')));
    expect(
      properties.listeners.keys,
      unorderedEquals(['metadata', 'media-title']),
    );
  });

  test('only a changed title emits another metadata event', () async {
    expect(events, hasLength(1));
    await properties.change('metadata');
    properties.values['metadata/by-key/icy-name'] = 'Updated station name';
    await properties.change('metadata');
    expect(events, hasLength(1));
    properties.values['metadata/by-key/icy-title'] = 'Artist - Next Song';
    await properties.change('metadata');
    expect(events, hasLength(2));
    expect(events.last?.info?.title, 'Artist - Next Song');
  });

  test('media-title is a fallback for an identified ICY stream', () async {
    properties.values['metadata/by-key/icy-title'] = '';
    properties.values['media-title'] = 'Artist - Fallback Song';
    await properties.change('media-title');
    expect(events.last?.info?.title, 'Artist - Fallback Song');
  });

  test('a cleared ICY title clears the published song', () async {
    properties.values['metadata/by-key/icy-title'] = '';
    properties.values['media-title'] = '';
    await properties.change('metadata');
    expect(observer.value, isNull);
    expect(events, hasLength(2));
    expect(events.last, isNull);
  });

  test('ordinary file media-title is not advertised as ICY', () async {
    observer.setSource('file:///music/ordinary.mp3');
    properties.values
      ..['path'] = 'file:///music/ordinary.mp3'
      ..['metadata/by-key/icy-title'] = ''
      ..['metadata/by-key/icy-name'] = ''
      ..['metadata/by-key/icy-url'] = ''
      ..['media-title'] = 'ordinary.mp3';
    await properties.change('metadata');
    expect(observer.value, isNull);
    expect(events.last, isNull);
  });

  test(
    'switch clears metadata and rejects the previous native source',
    () async {
      observer.setSource('https://stream.example.invalid/b');
      expect(observer.value, isNull);
      expect(events.last, isNull);
      final count = events.length;
      await properties.change('metadata');
      expect(events, hasLength(count));
      properties.values['path'] = 'https://stream.example.invalid/b';
      await properties.change('metadata');
      expect(
        observer.value?.info?.title,
        "Northcape - Doesn't Feel Like A Long Way",
      );
      expect(events, hasLength(count + 1));
    },
  );

  test('a read finishing after source replacement cannot publish', () async {
    final pending = Completer<String>();
    properties.delayedTitle = pending;
    final refreshing = observer.refresh();
    await Future<void>.delayed(Duration.zero);
    observer.setSource('https://stream.example.invalid/b');
    pending.complete('Stale title');
    await refreshing;
    expect(observer.value, isNull);
    expect(events.last, isNull);
  });

  test(
    'dispose prevents further property access from an in-flight read',
    () async {
      final pending = Completer<String>();
      properties.delayedTitle = pending;
      final refreshing = observer.refresh();
      await Future<void>.delayed(Duration.zero);
      await observer.dispose();
      final readsAtDispose = properties.reads.length;
      pending.complete('Late title');
      await refreshing;
      expect(properties.reads, hasLength(readsAtDispose));
      expect(events, hasLength(1));
    },
  );

  test('dispose removes observers and ignores later refreshes', () async {
    final count = events.length;
    await observer.dispose();
    properties.values['metadata/by-key/icy-title'] = 'Late title';
    await observer.refresh();
    expect(properties.listeners, isEmpty);
    expect(events, hasLength(count));
  });
}
