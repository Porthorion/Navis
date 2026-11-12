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
    ValueNotifier<NowPlayingBackground>? backgroundSetting,
    ImageProvider<Object>? image,
    Widget? body,
  }) async {
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
          home: NowPlayingBackdrop(
            hasActivePlayback: true,
            coverArtId: 'cover-1',
            coverArtRevision: 0,
            artUrl: null,
            child:
                body ??
                Builder(
                  builder: (context) => Text(
                    NowPlayingArtworkLayerScope.of(context) ? 'scoped' : 'bare',
                    textDirection: TextDirection.ltr,
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
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
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
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

  testWidgets('failed Artwork falls back to the tint', (tester) async {
    await pump(
      tester,
      background: NowPlayingBackground.artwork,
      image: MemoryImage(Uint8List.fromList(<int>[0, 1, 2])),
    );
    expect(find.byKey(_artworkKey), findsNothing);
    expect(find.text('bare'), findsOneWidget);
    expect(decoration(tester).gradient, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('background changes retain the unkeyed player body state', (
    tester,
  ) async {
    final background = ValueNotifier(NowPlayingBackground.tinted);
    addTearDown(background.dispose);
    await pump(
      tester,
      background: background.value,
      backgroundSetting: background,
      body: const _BodyIdentity(),
    );
    final state = tester.state(find.byType(_BodyIdentity));
    for (final mode in [
      NowPlayingBackground.artwork,
      NowPlayingBackground.plain,
      NowPlayingBackground.tinted,
      NowPlayingBackground.artwork,
    ]) {
      background.value = mode;
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_BodyIdentity)), same(state));
    }
  });
}

class _BodyIdentity extends StatefulWidget {
  const new();
  @override
  State<_BodyIdentity> createState() => _BodyIdentityState();
}

class _BodyIdentityState extends State<_BodyIdentity> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
