import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_theme.dart';

// Pill (NavisCornerStyle.rounded) turns FABs and the header icon buttons into
// circles; Soft and Square keep their rounded rectangles.
const _seed = Color(0xFF009688);

ThemeData _theme(
  String mode,
  NavisCornerStyle corners, [
  NavisControlColor controls = NavisControlColor.accent,
]) {
  final adjustment = ColorAdjustment(controls: controls);
  return switch (mode) {
    'light' => buildLightTheme(_seed, corners: corners, adjustment: adjustment),
    'dark' => buildDarkTheme(_seed, corners: corners, adjustment: adjustment),
    _ => buildOledTheme(_seed, corners: corners, adjustment: adjustment),
  };
}

Future<void> _pump(WidgetTester tester, ThemeData theme, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

ShapeBorder? _shapeOf(WidgetTester tester, Finder button) => tester
    .widget<Material>(
      find.descendant(of: button, matching: find.byType(Material)).first,
    )
    .shape;

/// Whether [shape] paints a circle on a square [side] box (Pill's Stadium
/// does): a point near the corner lies outside a circle but inside any
/// rounded rectangle with a smaller corner.
bool _isCircle(ShapeBorder? shape, double side) {
  final path = shape!.getOuterPath(Offset.zero & Size.square(side));
  final edge = side / 2;
  return path.contains(Offset(edge, 0.5)) &&
      path.contains(Offset(0.5, edge)) &&
      !path.contains(Offset(side * 0.12, side * 0.12));
}

void main() {
  testWidgets('FABs are circles in Pill and keep their corners otherwise', (
    tester,
  ) async {
    final fab = find.byType(FloatingActionButton);
    final button = FloatingActionButton(
      onPressed: () {},
      child: const Icon(Icons.add),
    );

    await _pump(tester, _theme('dark', NavisCornerStyle.rounded), button);
    expect(_isCircle(_shapeOf(tester, fab), 56), isTrue);

    await _pump(tester, _theme('dark', NavisCornerStyle.soft), button);
    expect(_shapeOf(tester, fab), NavisShapeData.soft.lgShape);

    await _pump(tester, _theme('dark', NavisCornerStyle.square), button);
    expect(_shapeOf(tester, fab), NavisShapeData.square.lgShape);
  });

  testWidgets('the lyrics re-center FAB is a circle in Pill, kept otherwise', (
    tester,
  ) async {
    final lyrics = LyricsList(
      structuredLyrics: [
        StructuredLyrics(
          synced: true,
          line: List.generate(
            70,
            (i) => LyricLine(start: i * 1000, value: 'Line $i'),
          ),
        ),
      ],
    );
    final fab = find.byType(FloatingActionButton);
    for (final corners in NavisCornerStyle.values) {
      await _pump(
        tester,
        _theme('dark', corners),
        SizedBox(
          height: 400,
          child: LyricsDisplayWidget(
            lyrics: lyrics,
            currentPosition: const Duration(seconds: 10),
            onSeek: (_) {},
          ),
        ),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(LyricsDisplayWidget)),
          scrollDelta: const Offset(0, 200),
        ),
      );
      await tester.pump();
      final shape = _shapeOf(tester, fab);
      if (corners == NavisCornerStyle.rounded) {
        expect(_isCircle(shape, 40), isTrue);
      } else {
        expect(
          (shape! as RoundedRectangleBorder).borderRadius,
          NavisShapeData.forStyle(corners).scaledAll(12),
        );
      }
      // Leave no re-engage timer pending.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }
  });

  for (final mode in <String>['light', 'dark', 'oled']) {
    for (final controls in NavisControlColor.values) {
      testWidgets('compact header download button is a circle in Pill '
          '($mode ${controls.name})', (tester) async {
        final download = find.byKey(const ValueKey<String>('download'));
        final bar = EntityActionBar(
          compact: true,
          onPlay: () {},
          onShuffle: () {},
          secondary: <Widget>[
            EntitySecondaryAction(
              key: const ValueKey<String>('download'),
              compact: true,
              icon: const Icon(Icons.download_outlined),
              label: 'Download',
              onPressed: () {},
            ),
          ],
        );

        await _pump(
          tester,
          _theme(mode, NavisCornerStyle.rounded, controls),
          bar,
        );
        final size = tester.getSize(
          find.descendant(of: download, matching: find.byType(IconButton)),
        );
        expect(size.width, size.height);
        expect(_isCircle(_shapeOf(tester, download), size.width), isTrue);

        await _pump(tester, _theme(mode, NavisCornerStyle.soft, controls), bar);
        expect(
          (_shapeOf(tester, download)! as RoundedRectangleBorder).borderRadius,
          NavisShapeData.soft.controlAll,
        );
      });
    }
  }
}
