import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_scope.dart';
import 'package:navis/src/features/player/presentation/now_playing_backdrop.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';

const _seed = Color(0xFF3F7F6F);
const _tint = Color(0xFFD32F2F);
const _fallback = Color(0xFF111111);

final _backdrop = NowPlayingPublishedBackdrop(
  owner: Object(),
  imageKey: 'k',
  image: MemoryImage(Uint8List(0)),
  coverAverage: const Color(0xFF204060),
  useCoverAverage: true,
  tintColor: _tint,
);

Future<Color> _fill(
  WidgetTester tester, {
  required NowPlayingBackground pick,
  NowPlayingBackground? scope,
  bool scopeActive = true,
  bool flat = false,
  NowPlayingPublishedBackdrop? backdrop,
}) async {
  late Color result;
  final theme = buildDarkTheme(
    _seed,
    style: NavisColorStyle.pastel,
    flat: flat,
  );
  Widget probe = Builder(
    builder: (context) {
      result = queuePanelFill(context, pick, backdrop, _fallback);
      return const SizedBox.shrink();
    },
  );
  if (scope != null) {
    probe = NowPlayingArtworkLayerScope(
      active: scopeActive,
      background: scope,
      child: probe,
    );
  }
  await tester.pumpWidget(MaterialApp(theme: theme, home: probe));
  return result;
}

void main() {
  testWidgets('without a scope the panel keeps its opaque fallback', (
    tester,
  ) async {
    expect(
      await _fill(
        tester,
        pick: NowPlayingBackground.artwork,
        backdrop: _backdrop,
      ),
      _fallback,
    );
  });

  testWidgets('a pick equal to the layer behind keeps the see-through fill', (
    tester,
  ) async {
    final fill = await _fill(
      tester,
      pick: NowPlayingBackground.artwork,
      scope: NowPlayingBackground.artwork,
      backdrop: _backdrop,
    );
    expect(fill.a, kNowPlayingArtworkPanelAlpha);
    // A tinted layer carries no scope activity: stays the opaque fallback.
    expect(
      await _fill(
        tester,
        pick: NowPlayingBackground.tinted,
        scope: NowPlayingBackground.tinted,
        scopeActive: false,
        backdrop: _backdrop,
      ),
      _fallback,
    );
  });

  testWidgets('Plain is opaque over any layer', (tester) async {
    expect(
      await _fill(
        tester,
        pick: NowPlayingBackground.plain,
        scope: NowPlayingBackground.artwork,
        backdrop: _backdrop,
      ),
      _fallback,
    );
  });

  testWidgets('a different pick takes the solid menu fill', (tester) async {
    final fill = await _fill(
      tester,
      pick: NowPlayingBackground.tinted,
      scope: NowPlayingBackground.plain,
      backdrop: _backdrop,
    );
    final theme = Theme.of(tester.element(find.byType(SizedBox)));
    expect(fill.a, 1);
    expect(
      fill,
      nowPlayingMenuFill(
        layer: NowPlayingBackground.tinted,
        backdrop: _backdrop,
        scheme: theme.colorScheme,
        style: theme.extension<NavisColorStyleData>()!,
      ),
    );
  });

  testWidgets('Flat Tinted queue stays opaque like before (#560)', (
    tester,
  ) async {
    expect(
      await _fill(
        tester,
        pick: NowPlayingBackground.tinted,
        scope: NowPlayingBackground.tinted,
        flat: true,
        backdrop: _backdrop,
      ),
      _fallback,
    );
  });
}
