import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:path/path.dart' as p;
import 'package:navis/src/common_widgets/caption_tint_resolver.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/home/presentation/cover_colour_sampler.dart';
import 'package:navis/src/features/home/presentation/cover_colour_worker.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_theme.dart';

class _Counter {
  final List<String> requested = <String>[];

  Future<CoverColourField?> call(String id, {int revision = 0}) async {
    requested.add(id);
    return CoverColourField.uniform(const Color(0xFF336699));
  }
}

class _StoredArtwork extends PermanentArtworkStore {
  new(this.file)
    : super(readApplicationSupportDirectory: Directory.systemTemp.createTemp);

  final File file;

  @override
  File? loadedFileFor(String? coverArtId) => file;

  @override
  Future<File?> fileFor(String? coverArtId) async => file;
}

Widget _app(_Counter counter, Widget home, {PermanentArtworkStore? artwork}) {
  return ProviderScope(
    overrides: [
      subsonicApiProvider.overrideWithValue(null),
      coverArtShapeProvider.overrideWithValue('rounded'),
      if (artwork != null)
        permanentArtworkStoreProvider.overrideWithValue(artwork),
      coverColourDecoderProvider.overrideWithValue(counter.call),
      coverColourStoreProvider.overrideWithValue(const NullCoverColourStore()),
      coverColourWorkerProvider.overrideWithValue(InlineCoverColourWorker()),
    ],
    child: MaterialApp(
      theme: buildLightTheme(defaultColorSchemeSeedColor),
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: home),
    ),
  );
}

Widget _cell(int i) => SizedBox(
  height: 120,
  child: Stack(
    children: <Widget>[
      AlbumCardLabel(title: 'Album $i', subtitle: 'Artist', coverArtId: 'c$i'),
    ],
  ),
);

void main() {
  setUp(() {
    sharedCoverColourFieldCache.clear();
    clearCaptionTintMemo();
  });
  tearDown(sharedCoverColourFieldCache.clear);

  testWidgets('a card gone within the settle delay never requests', (
    tester,
  ) async {
    final counter = _Counter();
    await tester.pumpWidget(
      _app(
        counter,
        SizedBox(
          height: 120,
          child: Stack(
            children: const <Widget>[
              AlbumCardLabel(title: 'A', subtitle: 'B', coverArtId: 'x'),
            ],
          ),
        ),
      ),
    );
    await tester.pump(kCoverTintSettleDelay - const Duration(milliseconds: 50));
    await tester.pumpWidget(_app(counter, const SizedBox()));
    await tester.pump(const Duration(seconds: 1));
    expect(counter.requested, isEmpty);
  });

  testWidgets('a card that stays built requests once and tints', (
    tester,
  ) async {
    final counter = _Counter();
    await tester.pumpWidget(
      _app(
        counter,
        SizedBox(
          height: 120,
          child: Stack(
            children: const <Widget>[
              AlbumCardLabel(title: 'A', subtitle: 'B', coverArtId: 'x'),
            ],
          ),
        ),
      ),
    );
    await tester.pump(kCoverTintSettleDelay + const Duration(milliseconds: 10));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(counter.requested, <String>['x']);
    expect(
      find.byKey(const ValueKey<String>('albumCardCoverTint')),
      findsOneWidget,
    );
  });

  testWidgets('a cached cover ready synchronously requests without settling', (
    tester,
  ) async {
    final counter = _Counter();
    final ready = ValueNotifier<bool>(true);
    addTearDown(ready.dispose);
    await tester.pumpWidget(
      _app(
        counter,
        SizedBox(
          height: 120,
          child: Stack(
            children: <Widget>[
              AlbumCardLabel(
                title: 'A',
                subtitle: 'B',
                coverArtId: 'cached',
                coverReady: ready,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(counter.requested, <String>['cached']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a synchronous cached cover still defers while scrolling', (
    tester,
  ) async {
    final counter = _Counter();
    final ready = ValueNotifier<bool>(true);
    addTearDown(ready.dispose);
    await tester.pumpWidget(
      _app(
        counter,
        ListView(
          children: <Widget>[
            SizedBox(
              height: 120,
              child: Stack(
                children: <Widget>[
                  AlbumCardLabel(
                    title: 'Cached',
                    subtitle: 'Artist',
                    coverArtId: 'cached',
                    coverReady: ready,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 1000),
          ],
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, -50));
    await tester.pump(const Duration(milliseconds: 1));
    expect(counter.requested, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(counter.requested, <String>['cached']);
    await tester.pumpWidget(const SizedBox());
  });

  for (final hero in [false, true]) {
    testWidgets(
      'a decoded cached ${hero ? 'hero' : 'regular'} cover skips settling',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'navis-tint-ready-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final file = File(p.join(directory.path, 'cover.png'))
          ..writeAsBytesSync(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
            ),
          );
        final counter = _Counter();
        final artwork = _StoredArtwork(file);
        final card = AlbumCard(
          extent: 120,
          heroTag: hero ? 'cached-hero' : null,
          album: AlbumsTableData(
            id: 'cached-album',
            name: 'Cached',
            coverArt: 'cached-cover',
            artists: const [],
            songsHydrated: true,
            isProvisional: false,
            isExternal: false,
          ),
        );
        // Decode once, then remount a fresh card with the image still cached.
        Widget app() => _app(counter, card, artwork: artwork);
        await tester.pumpWidget(app());
        for (
          var i = 0;
          i < 50 &&
              !tester
                  .widgetList<RawImage>(find.byType(RawImage))
                  .any((image) => image.image != null);
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        await tester.pump();
        final raw = tester.widget<RawImage>(find.byType(RawImage).first);
        expect(raw.image, isNotNull);
        expect(counter.requested, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(app());
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(counter.requested, <String>['cached-cover']);
        await tester.pumpWidget(const SizedBox());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      },
    );
  }

  testWidgets('a card waits for its cover before sampling', (tester) async {
    final counter = _Counter();
    final ready = ValueNotifier<bool>(false);
    addTearDown(ready.dispose);
    await tester.pumpWidget(
      _app(
        counter,
        SizedBox(
          height: 120,
          child: Stack(
            children: <Widget>[
              AlbumCardLabel(
                title: 'A',
                subtitle: 'B',
                coverArtId: 'x',
                coverReady: ready,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(counter.requested, isEmpty);
    ready.value = true;
    await tester.pump(kCoverTintSettleDelay - const Duration(milliseconds: 1));
    expect(counter.requested, isEmpty);
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(counter.requested, <String>['x']);
  });

  testWidgets('flinging a long grid samples a small share of its cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final counter = _Counter();
    final built = <int>{};
    await tester.pumpWidget(
      _app(
        counter,
        GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
          ),
          itemCount: 4000,
          itemBuilder: (context, i) {
            built.add(i);
            return _cell(i);
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final atRest = counter.requested.length;
    expect(atRest, lessThan(20));
    built.clear();

    for (var i = 0; i < 25; i++) {
      await tester.fling(find.byType(GridView), const Offset(0, -2500), 20000);
      for (var f = 0; f < 6; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
    expect(tester.takeException(), isNull);
    final sampled = counter.requested.length - atRest;
    expect(built.length, greaterThan(500));
    // Most cards flew past before settling; only the screenful visible when
    // each fling slowed may sample.
    expect(sampled * 3, lessThan(built.length));

    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  Iterable<Duration> tintDurations(WidgetTester tester) => tester
      .widgetList<TweenAnimationBuilder<CaptionTint>>(
        find.byKey(const ValueKey<String>('albumCardCoverTint')),
      )
      .map((w) => w.duration);

  void seed(int count) {
    for (var i = 0; i < count; i++) {
      sharedCoverColourFieldCache.put(
        'c$i',
        CoverColourField.uniform(
          Color(0xFF000000 | (i * 9973 + 4000) & 0xFFFFFF),
        ),
      );
    }
  }

  testWidgets('each caption has its own repaint boundary', (tester) async {
    await tester.pumpWidget(_app(_Counter(), _cell(0)));
    expect(
      find.byKey(const ValueKey<String>('albumCardCaptionLayer')),
      findsOneWidget,
    );
    expect(
      tester.widget(
        find.byKey(const ValueKey<String>('albumCardCaptionLayer')),
      ),
      isA<RepaintBoundary>(),
    );
  });

  testWidgets('a lone tint on an idle list fades', (tester) async {
    seed(1);
    await tester.pumpWidget(_app(_Counter(), _cell(0)));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    final durations = tintDurations(tester).toList();
    expect(durations, hasLength(1));
    expect(durations.single, greaterThan(Duration.zero));
  });

  testWidgets('a burst of tints applies instantly', (tester) async {
    seed(8);
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        _Counter(),
        SingleChildScrollView(
          child: Column(
            children: <Widget>[for (var i = 0; i < 8; i++) _cell(i)],
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    final durations = tintDurations(tester).toList();
    expect(durations, hasLength(8));
    expect(durations, everyElement(Duration.zero));
  });

  testWidgets('tints arriving while the list scrolls apply instantly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    seed(100);
    await tester.pumpWidget(
      _app(
        _Counter(),
        ListView.builder(
          itemExtent: 120,
          itemCount: 100,
          itemBuilder: (context, i) => _cell(i),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    final gesture = await tester.startGesture(const Offset(200, 600));
    for (var step = 0; step < 6; step++) {
      await gesture.moveBy(const Offset(0, -150));
      // One new caption per pump or so: never a burst of several.
      await tester.pump();
      await tester.pump();
    }
    final durations = tintDurations(tester).toList();
    expect(durations, isNotEmpty);
    // Cards built and tinted during the drag skip the fade.
    expect(durations.where((d) => d == Duration.zero), isNotEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
