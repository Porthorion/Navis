import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_theme.dart';

const _seed = Color(0xFF009688);

CoverColourField _field() => CoverColourField(const <Color>[
  Color(0xFFD32F2F),
  Color(0xFFD32F2F),
  Color(0xFF1976D2),
  Color(0xFFD32F2F),
  Color(0xFF388E3C),
  Color(0xFF1976D2),
  Color(0xFF388E3C),
  Color(0xFF388E3C),
  Color(0xFF1976D2),
]);

Future<ThemeData> _pump(
  WidgetTester tester, {
  required NavisColorStyle style,
  CoverColourField? field,
}) async {
  final theme = buildDarkTheme(_seed, style: style);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backgroundCoverColourFieldProvider.overrideWith(
          (ref, id) async => field,
        ),
      ],
      child: MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: SizedBox(
            width: 300,
            height: 200,
            child: ShowcaseColourWash(coverArtId: 'cover-1'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return theme;
}

void main() {
  testWidgets('wash retains cached colour while its new revision loads', (
    tester,
  ) async {
    sharedCoverColourFieldCache.clear();
    addTearDown(sharedCoverColourFieldCache.clear);
    final old = _field();
    sharedCoverColourFieldCache.put('cover', old);
    final gate = Completer<CoverColourField?>();
    final requested = <(String, int)>[];
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backgroundCoverColourFieldProvider.overrideWith((ref, key) {
            requested.add(key);
            return key.$2 == 0 ? Future.value(old) : gate.future;
          }),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(_seed),
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: revision,
              builder: (context, rev, _) => SizedBox(
                width: 300,
                height: 200,
                child: ShowcaseColourWash(
                  coverArtId: 'cover',
                  coverArtRevision: rev,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Color fill() {
      final painter = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byKey(const ValueKey<String>('home-showcase-wash')),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((paint) => paint.painter)
          .whereType<CoverColourFieldPainter>()
          .single;
      return painter.field.colors.first;
    }

    final oldFill = fill();
    revision.value = 1;
    await tester.pump();
    expect(fill(), oldFill);
    expect(requested, [('cover', 0), ('cover', 1)]);
    gate.complete(CoverColourField.uniform(const Color(0xFF1976D2)));
    await tester.pumpAndSettle();
    expect(fill(), isNot(oldFill));
  });

  testWidgets('shades the cover colours as a mesh under a veil', (
    tester,
  ) async {
    await _pump(tester, style: NavisColorStyle.pastel, field: _field());
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home-showcase-wash')),
        matching: find.byType(DecoratedBox),
      ),
      findsWidgets,
    );
  });
}
