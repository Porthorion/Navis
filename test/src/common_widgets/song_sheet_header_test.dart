import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/song_sheet_header.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_theme.dart';

// The test font is wide: about 18 characters per line at 390 px, so this
// needs 3 lines (a real font needs a longer title for the same).
const _longTitle = 'A Long Song Title That Needs Three Lines (Live)';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    String title = _longTitle,
    String? artist = 'Artist',
    String? album = 'Album',
    TextDirection direction = TextDirection.ltr,
  }) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final db = createTestDatabase();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(db),
        child: MaterialApp(
          theme: testTheme(),
          builder: (context, child) =>
              Directionality(textDirection: direction, child: child!),
          home: Scaffold(
            body: SongSheetHeader(title: title, artist: artist, album: album),
          ),
        ),
      ),
    );
  }

  testWidgets('shows a long title in full, wrapped to at most 3 lines', (
    tester,
  ) async {
    await pump(tester);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.text(_longTitle),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(paragraph.maxLines, 3);
    expect(paragraph.size.height, greaterThan(paragraph.text.style!.fontSize!));
  });

  testWidgets('shows "Artist · Album" on one line', (tester) async {
    await pump(tester);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('Artist · Album'),
    );
    expect(paragraph.maxLines, 1);
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('drops a missing album', (tester) async {
    await pump(tester, album: null);
    expect(find.text('Artist'), findsOneWidget);
  });

  testWidgets('drops a missing artist and a blank album', (tester) async {
    await pump(tester, artist: null, album: '');
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('is one header node for screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    final data = tester
        .getSemantics(find.byType(SongSheetHeader))
        .getSemanticsData();
    expect(data.flagsCollection.isHeader, isTrue);
    expect(data.label, contains(_longTitle));
    expect(data.label, contains('Artist · Album'));
    handle.dispose();
  });

  testWidgets('keeps an RTL title readable under an LTR app', (tester) async {
    const rtl = 'اسم أغنية طويل جدا يستمر هنا';
    await pump(tester, title: rtl);
    final paragraph = tester.renderObject<RenderParagraph>(find.text(rtl));
    expect(paragraph.textDirection, TextDirection.rtl);
    expect(paragraph.didExceedMaxLines, isFalse);
  });
}
