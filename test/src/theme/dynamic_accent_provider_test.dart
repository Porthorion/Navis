import 'dart:async';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart' show AudioServiceRepeatMode;
import 'package:file/file.dart' show File;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';

class _SongIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void next() => state++;
}

final _songIndexProvider = NotifierProvider<_SongIndexNotifier, int>(
  _SongIndexNotifier.new,
);

class _CurrentSongNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  String? get songId => state;
  set songId(String? value) => state = value;
}

final _currentSongProvider = NotifierProvider<_CurrentSongNotifier, String?>(
  _CurrentSongNotifier.new,
);

class _UnusedFileSystem implements FileSystem {
  @override
  Future<File> createFile(String name) => throw UnimplementedError();
}

class _ControlledAccentCache extends DynamicAccentColorCache {
  final Map<String, Completer<int?>> seeds = <String, Completer<int?>>{};

  Completer<int?> gate(String source) =>
      seeds.putIfAbsent(source, Completer<int?>.new);

  @override
  Future<int?> resolve({
    required String source,
    required SubsonicApiClient? api,
    required BaseCacheManager cacheManager,
  }) => gate(source).future;
}

/// Counts extractions instead of decoding an image; each call waits on a
/// completer the test controls.
class _CountingAccentCache extends DynamicAccentColorCache {
  final List<Completer<int?>> extractions = <Completer<int?>>[];

  @override
  Future<int?> extractSeed(ImageProvider<Object> image) {
    final completer = Completer<int?>();
    extractions.add(completer);
    return completer.future;
  }
}

CacheManager _unusedCacheManager() => CacheManager(
  Config(
    'navis-accent-test',
    repo: NonStoringObjectProvider(),
    fileSystem: _UnusedFileSystem(),
  ),
);

/// Records every source asked for and serves seeds from a map the way the
/// real cache does after a successful extraction.
class _RecordingAccentCache extends DynamicAccentColorCache {
  final List<String> requested = <String>[];
  final Map<String, int> seeds = <String, int>{};
  Completer<int?>? holdCurrent;
  bool failResolve = false;

  @override
  int? peek(String source) => seeds[source];

  @override
  Future<int?> resolve({
    required String source,
    required SubsonicApiClient? api,
    required BaseCacheManager cacheManager,
  }) {
    requested.add(source);
    if (failResolve) return Future<int?>.error(StateError('offline'));
    final hold = holdCurrent;
    if (hold != null && requested.length == 1) return hold.future;
    return Future<int?>.value(seeds[source] = 0xFF000000 + source.length);
  }
}

class _SnapshotNotifier extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();

  // ignore: use_setters_to_change_properties, a Notifier cannot expose one.
  void set(PlaybackSnapshot value) => state = value;
}

final _snapshotProvider = NotifierProvider<_SnapshotNotifier, PlaybackSnapshot>(
  _SnapshotNotifier.new,
);

PlaybackSnapshot _queueAt(
  List<String> ids,
  int index, {
  AudioServiceRepeatMode repeat = AudioServiceRepeatMode.none,
  RadioStationMetadata? radio,
}) => const PlaybackSnapshot.idle().copyWith(
  queueSongIds: ids,
  currentSongId: ids[index],
  currentIndex: index,
  repeatMode: repeat,
  radioStation: radio,
);

SongsTableData _song(String id, String? coverArt) => SongsTableData(
  id: id,
  title: 't',
  track: 1,
  artistName: 'a',
  albumName: 'b',
  duration: 1,
  isProvisional: false,
  isExternal: false,
  coverArt: coverArt,
);

void main() {
  testWidgets('palette decode errors fall back without escaping', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final scheme = await artworkColorScheme(
        provider: MemoryImage(Uint8List.fromList([0, 1, 2])),
        brightness: Brightness.light,
      );
      expect(scheme, isNull);
    });
    expect(tester.takeException(), isNull);
  });
  group('DynamicAccentColorCache.resolve', () {
    const source = 'url:https://example.test/a.jpg';

    Future<int?> resolve(DynamicAccentColorCache cache, [String? s]) =>
        cache.resolve(
          source: s ?? source,
          api: null,
          cacheManager: _unusedCacheManager(),
        );

    test('concurrent callers for one source share one extraction', () async {
      final cache = _CountingAccentCache();
      final first = resolve(cache);
      final second = resolve(cache);
      await pumpEventQueue();

      expect(cache.extractions, hasLength(1));
      cache.extractions.single.complete(0xFF112233);
      expect(await first, 0xFF112233);
      expect(await second, 0xFF112233);
      expect(cache.peek(source), 0xFF112233);

      // Now cached: no further extraction.
      expect(await resolve(cache), 0xFF112233);
      expect(cache.extractions, hasLength(1));
    });

    test('different sources extract independently', () async {
      final cache = _CountingAccentCache();
      unawaited(resolve(cache));
      unawaited(resolve(cache, 'url:https://example.test/b.jpg'));
      await pumpEventQueue();

      expect(cache.extractions, hasLength(2));
    });

    test('a null result is shared but not cached', () async {
      final cache = _CountingAccentCache();
      final first = resolve(cache);
      final second = resolve(cache);
      await pumpEventQueue();
      cache.extractions.single.complete(null);
      expect(await first, isNull);
      expect(await second, isNull);
      expect(cache.peek(source), isNull);

      final retry = resolve(cache);
      await pumpEventQueue();
      expect(cache.extractions, hasLength(2));
      cache.extractions.last.complete(0xFF445566);
      expect(await retry, 0xFF445566);
    });

    test('a failed extraction releases the entry', () async {
      final cache = _CountingAccentCache();
      final first = resolve(cache);
      final second = resolve(cache);
      await pumpEventQueue();
      cache.extractions.single.completeError(StateError('decode failed'));
      expect(await first, isNull);
      expect(await second, isNull);

      final retry = resolve(cache);
      await pumpEventQueue();
      expect(cache.extractions, hasLength(2));
      cache.extractions.last.complete(0xFF778899);
      expect(await retry, 0xFF778899);
    });
  });

  group('effectiveColorSchemeSeedProvider', () {
    test('falls back to selected seed when dynamic seed is null', () async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          colorSchemeSeedProvider.overrideWith((_) => 0xFF123456),
          dynamicAccentSeedColorProvider.overrideWith((_) async => null),
        ],
      );
      addTearDown(container.dispose);

      await container.read(dynamicAccentSeedColorProvider.future);
      final effective = container.read(effectiveColorSchemeSeedProvider);

      expect(effective, 0xFF123456);
    });

    test('uses dynamic seed when available', () async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          colorSchemeSeedProvider.overrideWith((_) => 0xFF123456),
          dynamicAccentSeedColorProvider.overrideWith((_) async => 0xFFABCDEF),
        ],
      );
      addTearDown(container.dispose);

      await container.read(dynamicAccentSeedColorProvider.future);
      final effective = container.read(effectiveColorSchemeSeedProvider);

      expect(effective, 0xFFABCDEF);
    });

    group('while the next dynamic seed loads', () {
      ProviderContainer makeContainer(Map<int, Completer<int?>> seeds) {
        return ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            colorSchemeSeedProvider.overrideWith((_) => 0xFF123456),
            dynamicAccentSeedColorProvider.overrideWith((ref) {
              return seeds[ref.watch(_songIndexProvider)]!.future;
            }),
          ],
        );
      }

      Future<ProviderContainer> resolvedTo(
        Map<int, Completer<int?>> seeds,
        int? seed,
      ) async {
        final container = makeContainer(seeds);
        addTearDown(container.dispose);
        final subscription = container.listen(
          effectiveColorSchemeSeedProvider,
          (_, _) {},
        );
        addTearDown(subscription.close);

        final first = container.read(dynamicAccentSeedColorProvider.future);
        seeds[0]!.complete(seed);
        await first;
        return container;
      }

      test('keeps the previous dynamic seed', () async {
        final seeds = {0: Completer<int?>(), 1: Completer<int?>()};
        final container = await resolvedTo(seeds, 0xFFABCDEF);
        expect(container.read(effectiveColorSchemeSeedProvider), 0xFFABCDEF);

        container.read(_songIndexProvider.notifier).next();
        expect(
          container.read(dynamicAccentSeedColorProvider).isLoading,
          isTrue,
        );
        expect(container.read(effectiveColorSchemeSeedProvider), 0xFFABCDEF);

        final second = container.read(dynamicAccentSeedColorProvider.future);
        seeds[1]!.complete(0xFF00FF00);
        await second;
        expect(container.read(effectiveColorSchemeSeedProvider), 0xFF00FF00);
      });

      test(
        'falls back to the selected seed when the previous was null',
        () async {
          final seeds = {0: Completer<int?>(), 1: Completer<int?>()};
          final container = await resolvedTo(seeds, null);
          expect(container.read(effectiveColorSchemeSeedProvider), 0xFF123456);

          container.read(_songIndexProvider.notifier).next();
          expect(
            container.read(dynamicAccentSeedColorProvider).isLoading,
            isTrue,
          );
          expect(container.read(effectiveColorSchemeSeedProvider), 0xFF123456);
        },
      );

      test(
        'falls back to the selected seed when the next one errors',
        () async {
          final seeds = {0: Completer<int?>(), 1: Completer<int?>()};
          final container = await resolvedTo(seeds, 0xFFABCDEF);

          container.read(_songIndexProvider.notifier).next();
          seeds[1]!.completeError(StateError('extract failed'));
          await expectLater(
            container.read(dynamicAccentSeedColorProvider.future),
            throwsA(isA<StateError>()),
          );
          expect(container.read(effectiveColorSchemeSeedProvider), 0xFF123456);
        },
      );

      test(
        'falls back to the selected seed when the next one is null',
        () async {
          final seeds = {0: Completer<int?>(), 1: Completer<int?>()};
          final container = await resolvedTo(seeds, 0xFFABCDEF);

          container.read(_songIndexProvider.notifier).next();
          final second = container.read(dynamicAccentSeedColorProvider.future);
          seeds[1]!.complete(null);
          await second;
          expect(container.read(effectiveColorSchemeSeedProvider), 0xFF123456);
        },
      );
    });
  });

  group('through the real song source chain', () {
    const selectedSeed = 0xFF123456;
    const seedA = 0xFFAA0000;
    const seedB = 0xFFBB0000;

    late _ControlledAccentCache cache;

    ProviderContainer makeContainer({
      bool enabled = true,
      required Stream<SongsTableData?> Function(String songId) rows,
    }) {
      cache = _ControlledAccentCache();
      return ProviderContainer(
        overrides: [
          colorSchemeSeedProvider.overrideWith((_) => selectedSeed),
          dynamicAccentEnabledProvider.overrideWith((_) => enabled),
          subsonicApiProvider.overrideWithValue(null),
          coverArtCacheManagerProvider.overrideWithValue(
            CacheManager(
              Config(
                'navis-accent-test',
                repo: NonStoringObjectProvider(),
                fileSystem: _UnusedFileSystem(),
              ),
            ),
          ),
          dynamicAccentColorCacheProvider.overrideWithValue(cache),
          playerStateProvider.overrideWith(
            (ref) => const PlaybackSnapshot.idle().copyWith(
              currentSongId: ref.watch(_currentSongProvider),
            ),
          ),
          songByIdProvider.overrideWith((ref, songId) => rows(songId)),
        ],
      );
    }

    Future<void> showA(ProviderContainer container) async {
      container.read(_currentSongProvider.notifier).songId = 'a';
      await pumpEventQueue();
    }

    test('keeps the album colour while the next song row loads', () async {
      final rows = <String, StreamController<SongsTableData?>>{
        'a': StreamController<SongsTableData?>(),
        'b': StreamController<SongsTableData?>(),
      };
      final container = makeContainer(rows: (id) => rows[id]!.stream);
      // Registered before dispose so it runs after it (teardowns are LIFO):
      // closing a controller whose stream is paused by an unlistened
      // Riverpod provider would never complete.
      addTearDown(() async {
        for (final controller in rows.values) {
          await controller.close();
        }
      });
      addTearDown(container.dispose);

      final log = <int?>[];
      final subscription = container.listen(
        effectiveColorSchemeSeedProvider,
        (_, next) => log.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await showA(container);
      rows['a']!.add(_song('a', 'ca'));
      await pumpEventQueue();
      cache.gate('id:ca').complete(seedA);
      await pumpEventQueue();

      expect(container.read(effectiveColorSchemeSeedProvider), seedA);
      expect(log, [selectedSeed, seedA]);

      container.read(_currentSongProvider.notifier).songId = 'b';
      await pumpEventQueue();

      // Song B's row has not arrived yet: hold album A's colour instead of
      // falling back to the selected seed.
      expect(container.read(effectiveColorSchemeSeedProvider), seedA);
      expect(log, [selectedSeed, seedA]);

      rows['b']!.add(_song('b', 'cb'));
      await pumpEventQueue();
      expect(container.read(effectiveColorSchemeSeedProvider), seedA);
      expect(log, [selectedSeed, seedA]);

      cache.gate('id:cb').complete(seedB);
      await pumpEventQueue();

      expect(log, [selectedSeed, seedA, seedB]);
    });

    test('falls back to the selected seed when the song row is null', () async {
      final rows = <String, StreamController<SongsTableData?>>{
        'a': StreamController<SongsTableData?>(),
        'z': StreamController<SongsTableData?>(),
      };
      final container = makeContainer(rows: (id) => rows[id]!.stream);
      // Registered before dispose so it runs after it (teardowns are LIFO):
      // closing a controller whose stream is paused by an unlistened
      // Riverpod provider would never complete.
      addTearDown(() async {
        for (final controller in rows.values) {
          await controller.close();
        }
      });
      addTearDown(container.dispose);

      final log = <int?>[];
      final subscription = container.listen(
        effectiveColorSchemeSeedProvider,
        (_, next) => log.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await showA(container);
      rows['a']!.add(_song('a', 'ca'));
      await pumpEventQueue();
      cache.gate('id:ca').complete(seedA);
      await pumpEventQueue();
      expect(container.read(effectiveColorSchemeSeedProvider), seedA);

      container.read(_currentSongProvider.notifier).songId = 'z';
      await pumpEventQueue();
      rows['z']!.add(null);
      await pumpEventQueue();

      expect(container.read(effectiveColorSchemeSeedProvider), selectedSeed);
      expect(log, [selectedSeed, seedA, selectedSeed]);
    });

    test('falls back to the selected seed when the feature is off', () async {
      final rowsB = StreamController<SongsTableData?>();
      final container = makeContainer(
        enabled: false,
        rows: (_) => rowsB.stream,
      );
      // Never listened (the feature is off), so its done future cannot
      // complete; close it without awaiting.
      addTearDown(() => unawaited(rowsB.close()));
      addTearDown(container.dispose);

      final log = <int?>[];
      final subscription = container.listen(
        effectiveColorSchemeSeedProvider,
        (_, next) => log.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      container.read(_currentSongProvider.notifier).songId = 'a';
      await pumpEventQueue();
      rowsB.add(_song('a', 'ca'));
      await pumpEventQueue();

      expect(container.read(effectiveColorSchemeSeedProvider), selectedSeed);
      expect(log, [selectedSeed]);
      expect(cache.seeds, isEmpty);
    });
  });

  group('next track prefetch', () {
    late _RecordingAccentCache cache;
    late ProviderContainer container;

    Future<void> setUpContainer({
      bool enabled = true,
      Map<String, String?> covers = const {'a': 'ca', 'b': 'cb', 'c': 'cc'},
    }) async {
      cache = _RecordingAccentCache();
      container = ProviderContainer(
        overrides: [
          colorSchemeSeedProvider.overrideWith((_) => 0xFF123456),
          dynamicAccentEnabledProvider.overrideWith((_) => enabled),
          subsonicApiProvider.overrideWithValue(null),
          coverArtCacheManagerProvider.overrideWithValue(_unusedCacheManager()),
          dynamicAccentColorCacheProvider.overrideWithValue(cache),
          playerStateProvider.overrideWith(
            (ref) => ref.watch(_snapshotProvider),
          ),
          songByIdProvider.overrideWith(
            (ref, id) => Stream.value(
              covers.containsKey(id) ? _song(id, covers[id]) : null,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      // Hold the real consumers the app root holds.
      container.listen(effectiveColorSchemeSeedProvider, (_, _) {});
      container.listen(dynamicAccentNextPrefetchProvider, (_, _) {});
    }

    Future<void> play(PlaybackSnapshot snapshot) async {
      container.read(_snapshotProvider.notifier).set(snapshot);
      await pumpEventQueue();
    }

    test('requests the next cover once when the track changes', () async {
      await setUpContainer();
      await play(_queueAt(['a', 'b', 'c'], 0));
      expect(cache.requested, ['id:ca', 'id:cb']);

      await play(_queueAt(['a', 'b', 'c'], 1));
      // b is cached; c is the new next item. Nothing else is requested.
      expect(cache.requested, ['id:ca', 'id:cb', 'id:cb', 'id:cc']);
      expect(cache.requested.where((s) => s == 'id:cc'), hasLength(1));
    });

    test('does nothing when Dynamic Album Colour is off', () async {
      await setUpContainer(enabled: false);
      await play(_queueAt(['a', 'b', 'c'], 0));
      expect(cache.requested, isEmpty);
    });

    test('does nothing at the end of the queue with repeat off', () async {
      await setUpContainer();
      await play(_queueAt(['a', 'b'], 1));
      expect(cache.requested, ['id:cb']);
    });

    test('wraps to the first item with repeat all', () async {
      await setUpContainer();
      await play(_queueAt(['a', 'b'], 1, repeat: AudioServiceRepeatMode.all));
      expect(cache.requested, ['id:cb', 'id:ca']);
    });

    test('does nothing for repeat one or a single-item queue', () async {
      await setUpContainer();
      await play(_queueAt(['a', 'b'], 0, repeat: AudioServiceRepeatMode.one));
      expect(cache.requested, ['id:ca']);
      await play(_queueAt(['a'], 0, repeat: AudioServiceRepeatMode.all));
      expect(cache.requested, ['id:ca']);
    });

    test('skips a next cover equal to the current one', () async {
      await setUpContainer(covers: {'a': 'same', 'b': 'same'});
      await play(_queueAt(['a', 'b'], 0));
      expect(cache.requested, ['id:same']);
    });

    test('skips a next song without a cover or row', () async {
      await setUpContainer(covers: {'a': 'ca', 'b': null});
      await play(_queueAt(['a', 'b', 'missing'], 0));
      expect(cache.requested, ['id:ca']);
      await play(_queueAt(['a', 'b', 'missing'], 1));
      expect(cache.requested, ['id:ca']);
    });

    test('does nothing for an empty queue or radio', () async {
      await setUpContainer();
      await play(const PlaybackSnapshot.idle());
      expect(cache.requested, isEmpty);
      await play(
        _queueAt(
          ['a', 'b'],
          0,
          radio: const RadioStationMetadata(
            stationId: 'r',
            stationName: 'r',
            streamUrl: 'https://radio.test/s',
          ),
        ),
      );
      expect(cache.requested, isEmpty);
    });

    test('waits for the current album colour before prefetching', () async {
      await setUpContainer();
      cache.holdCurrent = Completer<int?>();
      await play(_queueAt(['a', 'b'], 0));
      expect(cache.requested, ['id:ca']);

      cache.holdCurrent!.complete(0xFF111111);
      await pumpEventQueue();
      expect(cache.requested, ['id:ca', 'id:cb']);
    });

    test('swallows prefetch errors', () async {
      await setUpContainer();
      cache.failResolve = true;
      await play(_queueAt(['a', 'b'], 0));
      await pumpEventQueue();
      expect(cache.requested, isNotEmpty);
    });
  });
}
