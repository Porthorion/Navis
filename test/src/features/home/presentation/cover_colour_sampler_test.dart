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
import 'package:navis/src/features/home/presentation/cover_colour_worker.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:path/path.dart' as p;

CoverColourField _field(int seed) => CoverColourField(<Color>[
  for (var i = 0; i < 9; i++) Color(0xFF000000 | ((seed * 9 + i) & 0xFFFFFF)),
]);

class _MemoryStore implements CoverColourStore {
  final Map<String, CoverColourField> saved = <String, CoverColourField>{};
  int flushes = 0;

  @override
  Future<List<MapEntry<String, CoverColourField>>> warm(int count) async =>
      saved.entries.toList();

  @override
  Future<CoverColourField?> lookup(String id) async => saved[id];

  @override
  void add(String id, CoverColourField field) => saved[id] = field;

  @override
  Future<void> flush() async => flushes++;
}

/// Decoder whose calls stay open until the test completes them.
class _GatedDecoder {
  final Map<String, Completer<CoverColourField?>> gates =
      <String, Completer<CoverColourField?>>{};
  final List<String> started = <String>[];
  final List<int> revisions = <int>[];
  int inFlight = 0;
  int maxInFlight = 0;

  Future<CoverColourField?> call(String id, {int revision = 0}) {
    started.add(id);
    revisions.add(revision);
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
}) => CoverColourSampler(
  decode: decoder.call,
  cache: cache ?? CoverColourFieldCache(),
  coordinator: CoverArtLoadCoordinator(
    maxActiveDownloads: 2,
    criticalReserve: 0,
  ),
  store: store ?? _MemoryStore(),
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

    test(
      'revision bump refreshes once and keeps stale colours meanwhile',
      () async {
        final old = _field(1);
        final store = _MemoryStore()..saved['cover'] = old;
        final cache = CoverColourFieldCache();
        final decoder = _GatedDecoder();
        final sampler = _sampler(decoder, store: store, cache: cache);
        addTearDown(sampler.dispose);
        await sampler.ready;
        final a = sampler.request('cover', revision: 1);
        final b = sampler.request('cover', revision: 1);
        await _settle();
        expect(decoder.started, ['cover']);
        expect(decoder.revisions, [1]);
        expect(cache.peek('cover'), old);
        expect(store.saved['cover'], old);
        decoder.complete('cover', _field(2));
        expect(await a.future, _field(2));
        expect(await b.future, _field(2));
        expect(cache.peek('cover')!.revision, 1);
        expect(store.saved['cover']!.revision, 1);
        expect(await sampler.request('cover', revision: 1).future, _field(2));
        expect(decoder.started, ['cover']);
        // An older caller cannot revert the newly sampled field.
        expect(await sampler.request('cover').future, _field(2));
      },
    );

    test(
      'many bumped covers stay lazy and queued refreshes can cancel',
      () async {
        final store = _MemoryStore();
        for (var i = 0; i < 2000; i++) {
          store.saved['cover$i'] = _field(i);
        }
        final decoder = _GatedDecoder();
        final cache = CoverColourFieldCache();
        final sampler = _sampler(decoder, store: store, cache: cache);
        addTearDown(sampler.dispose);
        await sampler.ready;
        expect(decoder.started, isEmpty);
        final a = sampler.request('cover0', revision: 1);
        final b = sampler.request('cover1', revision: 1);
        final gone = sampler.request('cover2', revision: 1)..cancel();
        await _settle();
        expect(decoder.started, ['cover0', 'cover1']);
        decoder.complete('cover0');
        decoder.complete('cover1');
        await Future.wait([a.future, b.future, gone.future]);
        expect(decoder.started.length, 2);
        expect(store.saved['cover2']!.revision, 0);
      },
    );

    test('late old revision cannot replace an evicted newer sample', () async {
      final gates = [
        Completer<CoverColourField?>(),
        Completer<CoverColourField?>(),
      ];
      final cache = CoverColourFieldCache(capacity: 1);
      final store = _MemoryStore();
      final sampler = CoverColourSampler(
        decode: (id, {revision = 0}) => gates[revision].future,
        cache: cache,
        store: store,
        coordinator: CoverArtLoadCoordinator(
          maxActiveDownloads: 2,
          criticalReserve: 0,
        ),
      );
      addTearDown(sampler.dispose);
      final old = sampler.request('cover');
      final fresh = sampler.request('cover', revision: 1);
      await _settle();
      gates[1].complete(_field(2));
      await fresh.future;
      cache.put('other', _field(3));
      gates[0].complete(_field(1));
      await old.future;
      expect(cache.peek('cover'), isNull);
      expect(await sampler.request('cover', revision: 1).future, _field(2));
      expect(store.saved['cover']!.revision, 1);
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
        decode: (id, {revision = 0}) async => throw StateError('boom'),
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

    test('a store hit outside the warmed set skips the decode', () async {
      final store = _MemoryStore()..saved['old'] = _field(7);
      final decoder = _GatedDecoder();
      final sampler = _sampler(decoder, store: store);
      // Not warmed: capacity of the cache is irrelevant to lookup.
      expect(await sampler.request('old').future, _field(7));
      expect(decoder.started, isEmpty);
      sampler.dispose();
    });

    test('file store round-trips, trims to the newest and scopes', () async {
      final dir = Directory.systemTemp.createTempSync('tint_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, FileCoverColourStore.fileName);
      final worker = InlineCoverColourWorker(
        core: CoverColourWorkerCore(capacity: 3),
      );
      final store = FileCoverColourStore(
        scope: 'a',
        worker: worker,
        readRootDirectory: () async => dir,
      );
      expect(await store.warm(10), isEmpty);
      for (var i = 0; i < 5; i++) {
        store.add('c$i', CoverColourField(_field(i).colors, revision: i));
      }
      await store.flush();
      expect(File(path).existsSync(), isTrue);

      final reopened = FileCoverColourStore(
        scope: 'a',
        worker: InlineCoverColourWorker(),
        readRootDirectory: () async => dir,
      );
      final warm = await reopened.warm(2);
      expect(warm.map((e) => e.key), <String>['c3', 'c4']);
      expect(warm.last.value, _field(4));
      expect(warm.last.value.revision, 4);
      expect((await reopened.lookup('c2'))!.revision, 2);
      expect(await reopened.lookup('c2'), _field(2));
      expect(await reopened.lookup('c0'), isNull);

      final other = FileCoverColourStore(
        scope: 'b',
        worker: InlineCoverColourWorker(),
        readRootDirectory: () async => dir,
      );
      expect(await other.warm(10), isEmpty);
      File(path).writeAsBytesSync(<int>[1, 2, 3]);
      final damaged = FileCoverColourStore(
        scope: 'a',
        worker: InlineCoverColourWorker(),
        readRootDirectory: () async => dir,
      );
      expect(await damaged.warm(10), isEmpty);
    });

    test('old NCF1 file loads and is upgraded on save', () async {
      final dir = Directory.systemTemp.createTempSync('tint_legacy');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Original layout: NCF1, scope "s", one entry "x", nine colours.
      final cells = ByteData(36);
      for (var i = 0; i < 9; i++) {
        cells.setUint32(i * 4, 0xFF112233);
      }
      final file = File(p.join(dir.path, FileCoverColourStore.fileName));
      file.writeAsBytesSync([
        0x4e,
        0x43,
        0x46,
        0x31,
        0,
        1,
        0x73,
        0,
        0,
        0,
        1,
        0,
        1,
        0x78,
        ...cells.buffer.asUint8List(),
      ]);
      final store = FileCoverColourStore(
        scope: 's',
        worker: InlineCoverColourWorker(),
        readRootDirectory: () async => dir,
      );
      final loaded = (await store.warm(1)).single.value;
      expect(loaded.colors.first, const Color(0xFF112233));
      expect(loaded.revision, 0);
      store.add('x', CoverColourField(_field(2).colors, revision: 3));
      await store.flush();
      expect(file.readAsBytesSync()[3], 0x32);
      final reopened = FileCoverColourStore(
        scope: 's',
        worker: InlineCoverColourWorker(),
        readRootDirectory: () async => dir,
      );
      expect((await reopened.lookup('x'))!.revision, 3);
    });

    test('writes are debounced inside the worker', () async {
      final dir = Directory.systemTemp.createTempSync('tint_debounce');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, FileCoverColourStore.fileName);
      final store = FileCoverColourStore(
        scope: 'a',
        worker: InlineCoverColourWorker(
          core: CoverColourWorkerCore(
            persistDelay: const Duration(milliseconds: 30),
          ),
        ),
        readRootDirectory: () async => dir,
      );
      await store.warm(1);
      store.add('x', _field(1));
      expect(File(path).existsSync(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(File(path).existsSync(), isTrue);
    });

    test('a truncated file keeps the entries before the damage', () {
      final bytes = encodeColourStoreEntries(<String, List<int>>{
        'one': List<int>.filled(9, 0xFF112233),
        'two': List<int>.filled(9, 0xFF445566),
      }, scope: 's');
      final cut = Uint8List.sublistView(bytes, 0, bytes.length - 10);
      expect(decodeColourStoreEntries(cut, scope: 's').keys, <String>['one']);
    });
  });

  group('worker isolate', () {
    test('computes averages, tints and persistence off this isolate', () async {
      final worker = IsolateCoverColourWorker();
      addTearDown(worker.dispose);
      final pixels = Uint8List(6 * 6 * 4);
      for (var i = 0; i < 36; i++) {
        pixels[i * 4] = 200;
        pixels[i * 4 + 1] = 100;
        pixels[i * 4 + 2] = 50;
        pixels[i * 4 + 3] = 255;
      }
      expect(
        await worker.averageGrid(pixels, 6, 6),
        List<int>.filled(9, 0xFFC86432),
      );
      const style = NavisColorStyleData(
        style: NavisColorStyle.pastel,
        dark: true,
      );
      const sampled = Color(0xFFE53935);
      final expected = captionTintFor(sampled, style);
      final v = await worker.captionTint(sampled, style);
      expect(
        Color.from(alpha: v[0], red: v[1], green: v[2], blue: v[3]),
        expected.fill,
      );
      expect(
        Color.from(alpha: v[8], red: v[9], green: v[10], blue: v[11]),
        expected.subtext,
      );

      final dir = Directory.systemTemp.createTempSync('tint_isolate');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'f.bin');
      expect(await worker.openStore(path, 's', 5), isEmpty);
      worker.add('k', List<int>.filled(9, 0xFF010203));
      await worker.flush();
      expect(await worker.lookup('k'), List<int>.filled(9, 0xFF010203));
      expect(File(path).existsSync(), isTrue);
    });
  });

  group('local-only decoding', () {
    testWidgets('pixel averaging goes only through the worker seam', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('tint_seam');
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
      // The seam returns a colour the pixels cannot produce: seeing it in the
      // result proves the UI isolate did not average them itself.
      final worker = _SentinelWorker();
      final container = ProviderContainer(
        overrides: [
          coverArtCacheManagerProvider.overrideWithValue(
            _RecordingCacheManager(file: file),
          ),
          coverColourWorkerProvider.overrideWithValue(worker),
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
      expect(worker.calls, 1);
      expect(worker.lastBytes, 24 * 24 * 4);
      expect(field, CoverColourField.uniform(const Color(0xFF0A0B0C)));
    });

    test(
      'never reaches the network when the cover is not on the device',
      () async {
        final manager = _RecordingCacheManager();
        final container = ProviderContainer(
          overrides: [
            coverArtCacheManagerProvider.overrideWithValue(manager),
            coverColourWorkerProvider.overrideWithValue(
              InlineCoverColourWorker(),
            ),
            permanentArtworkStoreProvider.overrideWithValue(
              _EmptyArtworkStore(),
            ),
          ],
        );
        addTearDown(container.dispose);
        final decode = container.read(coverColourDecoderProvider);
        expect(await decode('missing'), isNull);
        expect(manager.cacheLookups, <String>[
          'missing:600',
          'missing:480',
          'missing:420',
          'missing:96',
        ]);
        expect(manager.otherCalls, isEmpty);
      },
    );

    for (final size in [600, 480, 420, 96]) {
      testWidgets('samples a revisioned remote cover cached only at $size px', (
        tester,
      ) async {
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
        final manager = _RecordingCacheManager(
          file: file,
          key: 'present:r2:$size',
        );
        final container = ProviderContainer(
          overrides: [
            coverArtCacheManagerProvider.overrideWithValue(manager),
            coverColourWorkerProvider.overrideWithValue(
              InlineCoverColourWorker(),
            ),
            permanentArtworkStoreProvider.overrideWithValue(
              _EmptyArtworkStore(),
            ),
          ],
        );
        addTearDown(container.dispose);
        CoverColourField? field;
        var done = false;
        unawaited(
          container
              .read(coverColourDecoderProvider)('present', revision: 2)
              .then((value) {
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
        expect(manager.cacheLookups.last, 'present:r2:$size');
      });
    }
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
  new({this.file, this.key});

  final File? file;
  final String? key;
  final List<String> cacheLookups = <String>[];
  final List<String> otherCalls = <String>[];

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    cacheLookups.add(key);
    final f = this.key == null || this.key == key ? file : null;
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

/// Returns a fixed grid and counts how often pixels were handed to it.
class _SentinelWorker extends InlineCoverColourWorker {
  int calls = 0;
  int lastBytes = 0;

  @override
  Future<List<int>> averageGrid(Uint8List rgba, int width, int height) async {
    calls++;
    lastBytes = rgba.length;
    return List<int>.filled(9, 0xFF0A0B0C);
  }
}
