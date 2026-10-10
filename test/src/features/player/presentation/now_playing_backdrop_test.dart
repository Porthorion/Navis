import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_source.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_scope.dart';
import 'package:navis/src/features/player/presentation/now_playing_backdrop.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_theme.dart';

Future<ImageProvider<Object>> _solid(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = color);
  final image = await recorder.endRecording().toImage(4, 4);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  return MemoryImage(Uint8List.view(bytes.buffer));
}

const _tint = Color(0xFFD32F2F);
const _surfaceKey = ValueKey<String>('nowPlayingSurfaceTint');
const _artworkKey = ValueKey<String>('nowPlayingArtworkBackground');

void main() {
  late ImageProvider<Object> cover;

  setUp(() async {
    cover = await _solid(const Color(0xFF3F7F6F));
    debugSeedNowPlayingTint(
      brightness: Brightness.dark,
      coverArtId: 'cover-1',
      tint: _tint,
    );
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required NowPlayingBackground background,
    bool flat = false,
    bool oled = false,
    bool publish = false,
    ValueNotifier<bool>? publishing,
    ValueNotifier<NowPlayingBackground>? backgroundSetting,
    ImageProvider<Object>? image,
  }) async {
    final publication = publishing ?? ValueNotifier(publish);
    if (publishing == null) addTearDown(publication.dispose);
    final theme = oled
        ? buildOledTheme(
            const Color(0xFF3F7F6F),
            style: NavisColorStyle.pastel,
            flat: flat,
          )
        : buildDarkTheme(
            const Color(0xFF3F7F6F),
            style: NavisColorStyle.pastel,
            flat: flat,
          );
    final container = ProviderContainer(
      overrides: [
        nowPlayingBackgroundProvider.overrideWith((ref) {
          if (backgroundSetting == null) return background;
          void changed() => ref.invalidateSelf();
          backgroundSetting.addListener(changed);
          ref.onDispose(() => backgroundSetting.removeListener(changed));
          return backgroundSetting.value;
        }),
        coverArtImageSourceProvider.overrideWith(
          (ref, key) async => image ?? cover,
        ),
        backgroundCoverColourFieldProvider.overrideWith(
          (ref, key) async => CoverColourField.uniform(const Color(0xFF3F7F6F)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: theme,
          home: ValueListenableBuilder<bool>(
            valueListenable: publication,
            builder: (context, publish, _) => NowPlayingBackdrop(
              hasActivePlayback: true,
              coverArtId: 'cover-1',
              coverArtRevision: 0,
              artUrl: null,
              publishToQueueOverlay: publish,
              child: Builder(
                builder: (context) => Text(
                  NowPlayingArtworkLayerScope.of(context) ? 'scoped' : 'bare',
                  textDirection: TextDirection.ltr,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    return container;
  }

  BoxDecoration decoration(WidgetTester tester) =>
      tester.widget<AnimatedContainer>(find.byKey(_surfaceKey)).decoration!
          as BoxDecoration;

  testWidgets('Art-tinted fades the tint into the surface', (tester) async {
    await pump(tester, background: NowPlayingBackground.tinted);
    expect(decoration(tester).gradient, isNotNull);
    expect(find.byKey(_artworkKey), findsNothing);
    expect(find.text('bare'), findsOneWidget);
  });

  testWidgets('Artwork draws the blurred layer and scopes the child', (
    tester,
  ) async {
    await pump(tester, background: NowPlayingBackground.artwork);
    expect(find.byKey(_artworkKey), findsOneWidget);
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.text('scoped'), findsOneWidget);
    expect(decoration(tester).gradient, isNull);
  });

  testWidgets('Artwork under Flat falls back to the solid tint', (
    tester,
  ) async {
    await pump(tester, background: NowPlayingBackground.artwork, flat: true);
    expect(find.byKey(_artworkKey), findsNothing);
    expect(find.text('bare'), findsOneWidget);
    expect(decoration(tester).gradient, isNull);
    expect(decoration(tester).color, isNot(const Color(0x00000000)));
  });

  testWidgets('Plain is the plain surface', (tester) async {
    await pump(tester, background: NowPlayingBackground.plain);
    expect(find.byKey(_artworkKey), findsNothing);
    final theme = Theme.of(tester.element(find.byKey(_surfaceKey)));
    expect(decoration(tester).color, theme.colorScheme.surface);
    expect(decoration(tester).gradient, isNull);
  });

  testWidgets('OLED + Flat stays pure black', (tester) async {
    await pump(
      tester,
      background: NowPlayingBackground.tinted,
      flat: true,
      oled: true,
    );
    expect(decoration(tester).color, Colors.black);
    expect(decoration(tester).gradient, isNull);
  });

  testWidgets('publishes the Artwork layer and clears it afterwards', (
    tester,
  ) async {
    final container = await pump(
      tester,
      background: NowPlayingBackground.artwork,
      publish: true,
    );
    final published = container.read(nowPlayingPublishedBackdropProvider);
    expect(published, isNotNull);
    expect(published!.imageKey, startsWith('id:cover-1'));
    expect(published.coverAverage!.toARGB32(), 0xFF3F7F6F);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
  });

  testWidgets('does not publish without the flag, under Flat or Tinted', (
    tester,
  ) async {
    var container = await pump(
      tester,
      background: NowPlayingBackground.artwork,
    );
    expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
    container = await pump(
      tester,
      background: NowPlayingBackground.artwork,
      flat: true,
      publish: true,
    );
    expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
    container = await pump(
      tester,
      background: NowPlayingBackground.tinted,
      publish: true,
    );
    expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
  });

  testWidgets('clears publication while the hidden backdrop stays mounted', (
    tester,
  ) async {
    final publishing = ValueNotifier(true);
    addTearDown(publishing.dispose);
    final container = await pump(
      tester,
      background: NowPlayingBackground.artwork,
      publishing: publishing,
    );
    expect(container.read(nowPlayingPublishedBackdropProvider), isNotNull);
    publishing.value = false;
    await tester.pump();
    expect(find.byKey(_artworkKey), findsOneWidget);
    expect(container.read(nowPlayingPublishedBackdropProvider), isNull);

    publishing.value = true;
    await tester.pump();
    expect(container.read(nowPlayingPublishedBackdropProvider), isNotNull);
  });

  testWidgets('failed Artwork falls back to tint and clears publication', (
    tester,
  ) async {
    final container = await pump(
      tester,
      background: NowPlayingBackground.artwork,
      publish: true,
      image: MemoryImage(Uint8List.fromList(<int>[0, 1, 2])),
    );
    expect(find.byKey(_artworkKey), findsNothing);
    expect(find.text('bare'), findsOneWidget);
    expect(decoration(tester).gradient, isNotNull);
    expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching away from Artwork clears the shared layer', (
    tester,
  ) async {
    final background = ValueNotifier(NowPlayingBackground.artwork);
    final container = await pump(
      tester,
      background: background.value,
      backgroundSetting: background,
      publish: true,
    );
    expect(container.read(nowPlayingPublishedBackdropProvider), isNotNull);
    background.value = NowPlayingBackground.tinted;
    await tester.pumpAndSettle();
    expect(find.byKey(_artworkKey), findsNothing);
    expect(decoration(tester).gradient, isNotNull);
    expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
    background.value = NowPlayingBackground.plain;
    await tester.pumpAndSettle();
    expect(decoration(tester).gradient, isNull);
    expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    background.dispose();
  });

  testWidgets('disposal clears a still-mounted external consumer', (
    tester,
  ) async {
    final container = await pump(
      tester,
      background: NowPlayingBackground.artwork,
      publish: true,
    );
    final backdrop = tester.widget<NowPlayingBackdrop>(
      find.byType(NowPlayingBackdrop),
    );
    final theme = tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: theme,
          home: Stack(
            fit: StackFit.expand,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (context, shown, _) =>
                    shown ? backdrop : const SizedBox.expand(),
              ),
              Consumer(
                builder: (context, ref, _) => Text(
                  ref.watch(nowPlayingPublishedBackdropProvider) == null
                      ? 'cleared'
                      : 'published',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('published'), findsOneWidget);
    visible.value = false;
    await tester.pumpAndSettle();
    expect(find.text('cleared'), findsOneWidget);
    expect(container.read(nowPlayingPublishedBackdropProvider), isNull);
    expect(tester.takeException(), isNull);
  });
}
