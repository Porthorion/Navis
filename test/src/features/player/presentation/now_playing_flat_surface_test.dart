import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

const _tint = Color(0xFFD32F2F);
const _surface = Color(0xFF101418);

Future<BoxDecoration> _pump(
  WidgetTester tester, {
  required Color? tintColor,
  required bool flat,
  NavisColorStyle style = NavisColorStyle.immersive,
  bool oled = false,
  Color surface = _surface,
}) async {
  final data = NavisColorStyleData(
    style: style,
    dark: true,
    flat: flat,
    oled: oled,
  );
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: DecoratedBox(
        key: const ValueKey<String>('surface'),
        decoration: nowPlayingSurfaceDecoration(
          tintColor: tintColor,
          colorStyle: data,
          surfaceColor: surface,
        ),
        child: const SizedBox.expand(),
      ),
    ),
  );
  return tester
          .widget<DecoratedBox>(find.byKey(const ValueKey<String>('surface')))
          .decoration
      as BoxDecoration;
}

void main() {
  for (final style in NavisColorStyle.values) {
    testWidgets('art-tinted + Flat is one solid colour (${style.name})', (
      tester,
    ) async {
      final decoration = await _pump(
        tester,
        tintColor: _tint,
        flat: true,
        style: style,
      );
      final data = NavisColorStyleData(style: style, dark: true, flat: true);
      expect(decoration.gradient, isNull);
      expect(
        decoration.color,
        Color.alphaBlend(
          data.adaptArtColor(_tint).withValues(alpha: data.nowPlayingTintAlpha),
          _surface,
        ),
      );
    });
  }

  testWidgets('art-tinted without Flat keeps the gradient', (tester) async {
    final decoration = await _pump(tester, tintColor: _tint, flat: false);
    expect(decoration.color, isNull);
    final gradient = decoration.gradient! as LinearGradient;
    expect(gradient.colors.last, _surface);
    expect(gradient.colors.first, isNot(_surface));
    expect(gradient.stops, const <double>[0, 0.7]);
  });

  for (final style in NavisColorStyle.values) {
    testWidgets('OLED + Flat stays plain black (${style.name})', (
      tester,
    ) async {
      final decoration = await _pump(
        tester,
        tintColor: _tint,
        flat: true,
        style: style,
        oled: true,
        surface: Colors.black,
      );
      expect(decoration.gradient, isNull);
      expect(decoration.color, Colors.black);
    });
  }

  testWidgets('OLED without Flat keeps the tinted gradient', (tester) async {
    final decoration = await _pump(
      tester,
      tintColor: _tint,
      flat: false,
      oled: true,
      surface: Colors.black,
    );
    expect(decoration.color, isNull);
    final gradient = decoration.gradient! as LinearGradient;
    expect(gradient.colors.last, Colors.black);
    expect(gradient.colors.first, isNot(Colors.black));
  });

  for (final flat in <bool>[true, false]) {
    testWidgets('art tint off is the plain surface (flat: $flat)', (
      tester,
    ) async {
      final decoration = await _pump(tester, tintColor: null, flat: flat);
      expect(decoration.gradient, isNull);
      expect(decoration.color, _surface);
    });
  }
}
