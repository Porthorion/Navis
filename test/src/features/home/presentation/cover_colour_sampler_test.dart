import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file/local.dart';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/home/presentation/cover_colour_sampler.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:path/path.dart' as p;

CoverColourField _field(int seed) => CoverColourField(<Color>[
  for (var i = 0; i < 9; i++) Color(0xFF000000 | ((seed * 9 + i) & 0xFFFFFF)),
]);

class _MemoryStore implements CoverColourStore {
  Map<String, CoverColourField> saved = <String, CoverColourField>{};
  int saves = 0;

  @override
  Future<Map<String, CoverColourField>> load() async =>
      Map<String, CoverColourField>.of(saved);

  @override
  Future<void> save(Map<String, CoverColourField> entries) async {
    saves++;
    saved = Map<String, CoverColourField>.of(entries);
  }
}

/// Decoder whose calls stay open until the test completes them.
class _GatedDecoder {
  final Map<String, Completer<CoverColourField?>> gates =
      <String, Completer<CoverColourField?>>{};
  final List<String> started = <String>[];
  int inFlight = 0;
  int maxInFlight = 0;

  Future<CoverColourField?> call(String id) {
    started.add(id);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final gate = gates[id] = Completer<CoverColourField?>();
    return gate.future.whenComplete(() => inFlight--);
  }

  void complete(String id, [CoverColourField? field]) =>
      gates[id]!.complete(field ?? _field(id.hashCode));
}

CoverColourSampler _sampler(
  _GatedDecoder decoder, {
  CoverColourStore? store,
  CoverColourFieldCache? cache,
  Duration persistDelay = const Duration(seconds: 2),
  int persistedCapacity = kCoverColourPersistedCapacity,
}) => CoverColourSampler(
  decode: decoder.call,
  cache: cache ?? CoverColourFieldCache(),
  coordinator: CoverArtLoadCoordinator(
    maxActiveDownloads: 2,
    criticalReserve: 0,
  ),
  store: store ?? _MemoryStore(),
  persistDelay: persistDelay,
  persistedCapacity: persistedCapacity,
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('CoverColourSampler queue', () {
    test('runs at most two decodes at once', () async {
      final decoder = _GatedDecoder();
      final sampler = _sampler(decoder);
      final requests = [for (var i = 0; i < 8; i++) sampler.request('c$i')];
      await _settle();
      expect(decoder.started.length, 2);
      for (var i = 0; i < 8; i++) {
        await _settle();
        decoder.complete(decoder.started[i]);
        await _settle();
        expect(decoder.inFlight, lessThanOrEqualTo(2));
      }
      await Future.wait(requests.map((r) => r.future));
      expect(decoder.started.length, 8);
      expect(decoder.maxInFlight, 2);
      sampler.dispose();
    });

    test('deduplicates concurrent requests for one cover', () async {
      final decoder = _GatedDecoder();
      final sampler = _sampler(decoder);
      final a = sampler.request('same');
      final b = sampler.request('same');
      await _settle();
      expect(decoder.started, <String>['same']);
      decoder.complete('same');
      expect(await a.future, isNotNull);
      expect(await b.future, await a.future);
      // The result is now in memory: no further decode.
      final c = sampler.request('same');
      expect(await c.future, isNotNull);
      expect(decoder.started.length, 1);
      sampler.dispose();
    });

    test('drops queued requests whose cards went away', () async {
      final decoder = _GatedDecoder();
      final sampler = _sampler(decoder);
      final running = [sampler.request('a'), sampler.request('b')];
      await _settle();
      expect(decoder.started, <String>['a', 'b']);
      final dropped = sampler.request('gone')..cancel();
      final kept = sampler.request('kept');
      await _settle();
      decoder.complete('a');
      decoder.complete('b');
      await _settle();
      expect(decoder.started, <String>['a', 'b', 'kept']);
      expect(await dropped.future, isNull);
      decoder.complete('kept');
      expect(await kept.future, isNotNull);
      await Future.wait(running.map((r) => r.future));
      sampler.dispose();
    });

    test('one cancelled claim leaves the shared decode running', () async {
      final decoder = _GatedDecoder();
      final sampler = _sampler(decoder);
      final a = sampler.request('x');
      final b = sampler.request('x');
      a.cancel();
      await _settle();
      decoder.complete('x');
      expect(await b.future, isNotNull);
      expect(await a.future, isNull);
      sampler.dispose();
    });

    test('a failing decode completes with null and frees its slot', () async {
      final sampler = CoverColourSampler(
        decode: (id) async => throw StateError('boom'),
        cache: CoverColourFieldCache(),
        coordinator: CoverArtLoadCoordinator(
          maxActiveDownloads: 2,
          criticalReserve: 0,
        ),
      );
      expect(await sampler.request('bad').future, isNull);
      expect(await sampler.request('bad2').future, isNull);
      sampler.dispose();
    });
  });

  group('persistent cache', () {
    test(
      'a sampled field is stored and later served without decoding',
      () async {
        final store = _MemoryStore();
        final decoder = _GatedDecoder();
        final first = _sampler(decoder, store: store);
        final request = first.request('album');
        await _settle();
        decoder.complete('album');
        final sampled = await request.future;
        await first.flush();
        expect(store.saved.keys, <String>['album']);
        first.dispose();

        final second = _GatedDecoder();
        final cache = CoverColourFieldCache();
        final reopened = _sampler(second, store: store, cache: cache);
        await reopened.ready;
        // Warmed into memory for the first frame.
        expect(cache.peek('album'), sampled);
        expect(await reopened.request('album').future, sampled);
        expect(second.started, isEmpty);
        reopened.dispose();
      },
    );

    test('keeps only the newest entries', () async {
      final store = _MemoryStore();
      final decoder = _GatedDecoder();
      final sampler = _sampler(decoder, store: store, persistedCapacity: 3);
      for (var i = 0; i < 5; i++) {
        final r = sampler.request('c$i');
        await _settle();
        decoder.complete('c$i');
        await r.future;
      }
      await sampler.flush();
      expect(store.saved.keys, <String>['c2', 'c3', 'c4']);
      sampler.dispose();
    });

    test('writes are debounced into one save', () async {
      final store = _MemoryStore();
      final decoder = _GatedDecoder();
      final sampler = _sampler(
        decoder,
        store: store,
        persistDelay: const Duration(milliseconds: 20),
      );
      for (var i = 0; i < 3; i++) {
        final r = sampler.request('c$i');
        await _settle();
        decoder.complete('c$i');
        await r.future;
      }
      expect(store.saves, 0);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(store.saves, 1);
      sampler.dispose();
    });

    test('file store round-trips and ignores another scope', () async {
      final dir = await Directory.systemTemp.createTemp('tint_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = FileCoverColourStore(
        scope: 'a',
        readRootDirectory: () async => dir,
      );
      await store.save(<String, CoverColourField>{
        'one': _field(1),
        'two': _field(2),
      });
      final loaded = await store.load();
      expect(loaded.keys, <String>['one', 'two']);
      expect(loaded['two'], _field(2));
      final other = FileCoverColourStore(
        scope: 'b',
        readRootDirectory: () async => dir,
      );
      expect(await other.load(), isEmpty);
      File(p.join(dir.path, FileCoverColourStore.fileName))
          .writeAsBytesSync(<int>[1, 2, 3]);
      expect(await store.load(), isEmpty);
    });

    test('a truncated file keeps the entries before the damage', () {
      final bytes = encodeCoverColourStore(<String, CoverColourField>{
        'one': _field(1),
        'two': _field(2),
      }, scope: 's');
      final cut = Uint8List.sublistView(bytes, 0, bytes.length - 10);
      expect(decodeCoverColourStore(cut, scope: 's').keys, <String>['one']);
    });
  });

  group('local-only decoding', () {
    test(
      'never reaches the network when the cover is not on the device',
      () async {
        final manager = _RecordingCacheManager();
        final container = ProviderContainer(
          overrides: [
            coverArtCacheManagerProvider.overrideWithValue(manager),
            permanentArtworkStoreProvider.overrideWithValue(
              _EmptyArtworkStore(),
            ),
          ],
        );
        addTearDown(container.dispose);
        final decode = container.read(coverColourDecoderProvider);
        expect(await decode('missing'), isNull);
        expect(manager.cacheLookups, <String>['missing:600']);
        expect(manager.otherCalls, isEmpty);
      },
    );

    testWidgets('samples a cover file that is already cached', (tester) async {
      final dir = Directory.systemTemp.createTempSync('tint_cover');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'cover.png'));
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 30, 30),
          Paint()..color = const Color(0xFF3366CC),
        );
        final image = await recorder.endRecording().toImage(30, 30);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        file.writeAsBytesSync(data!.buffer.asUint8List());
      });
      final manager = _RecordingCacheManager(file: file);
      final container = ProviderContainer(
        overrides: [
          coverArtCacheManagerProvider.overrideWithValue(manager),
          permanentArtworkStoreProvider.overrideWithValue(_EmptyArtworkStore()),
        ],
      );
      addTearDown(container.dispose);
      CoverColourField? field;
      var done = false;
      unawaited(
        container.read(coverColourDecoderProvider)('present').then((value) {
          field = value;
          done = true;
        }),
      );
      for (var i = 0; i < 100 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(field, isNotNull);
      expect(field!.colors.first, const Color(0xFF3366CC));
      expect(manager.otherCalls, isEmpty);
    });
  });
}

class _EmptyArtworkStore extends Fake implements PermanentArtworkStore {
  @override
  File? loadedFileFor(String? coverArtId) => null;

  @override
  Future<File?> fileFor(String? coverArtId) async => null;
}

/// A cache manager that serves one local file and records any call that
/// could reach the network (everything but the cache lookup).
class _RecordingCacheManager extends Fake implements CacheManager {
  new({this.file});

  final File? file;
  final List<String> cacheLookups = <String>[];
  final List<String> otherCalls = <String>[];

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    cacheLookups.add(key);
    final f = file;
    return f == null
        ? null
        : FileInfo(
            const LocalFileSystem().file(f.path),
            FileSource.Cache,
            DateTime(2100),
            key,
          );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    otherCalls.add(invocation.memberName.toString());
    return super.noSuchMethod(invocation);
  }
}
