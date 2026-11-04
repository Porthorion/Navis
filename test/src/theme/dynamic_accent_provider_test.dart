import 'dart:async';
import 'dart:typed_data';

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
}
