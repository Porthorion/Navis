import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/marquee_text.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/theme/navis_density_scope.dart';

const _long = 'A deliberately very long album title that cannot fit in a card';
const _style = TextStyle(fontSize: 13);
const _versioned = 'A long song title that will not fit (Radio Edit)';
const _suffix = ' (Radio Edit)';

Widget _host({
  String text = _long,
  double width = 120,
  bool reduceMotion = false,
  TextDirection direction = TextDirection.ltr,
  bool tickers = true,
  int? passes,
  bool active = true,
  int maxLines = 1,
  TextAlign textAlign = TextAlign.start,
  StrutStyle? strutStyle,
  double textScale = 1,
  bool? keepVersion,
}) => MaterialApp(
  home: Directionality(
    textDirection: direction,
    child: MediaQuery(
      data: MediaQueryData(
        disableAnimations: reduceMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: TickerMode(
        enabled: tickers,
        child: _maybeScope(
          keepVersion,
          Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: MarqueeText(
                  text,
                  style: _style,
                  passes: passes,
                  active: active,
                  maxLines: maxLines,
                  textAlign: textAlign,
                  strutStyle: strutStyle,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

/// The Keep Song Versions Visible setting reaches titles through the density
/// scope; without one (null) the default applies.
Widget _maybeScope(bool? keepVersion, Widget child) => keepVersion == null
    ? child
    : NavisDensityScope(
        density: NavisDensity.comfortable,
        keepTitleVersion: keepVersion,
        child: child,
      );

final _scrollers = find.descendant(
  of: find.byType(MarqueeText),
  matching: find.byType(Transform),
);

/// Zero while the title rests in its still form (it has no [Transform] then).
double _offset(WidgetTester tester) => _scrollers.evaluate().isEmpty
    ? 0
    : tester.widget<Transform>(_scrollers).transform.getTranslation().x;

bool _exceeds(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(text).didExceedMaxLines;

void main() {
  testWidgets('limited passes scroll, then rest at the start', (tester) async {
    await tester.pumpWidget(_host(passes: 2));
    await tester.pump(kMarqueeStartPause + const Duration(milliseconds: 500));
    expect(_offset(tester), lessThan(0));

    await tester.pumpAndSettle();
    expect(_offset(tester), 0);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a title that fits is a plain one-line Text', (tester) async {
    await tester.pumpWidget(_host(text: 'Short', width: 200));

    final text = tester.widget<Text>(find.text('Short'));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(
      find.descendant(
        of: find.byType(MarqueeText),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a long title rests, scrolls to its end, rests and resets', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    // The full text is only laid out while travelling.
    await tester.pump(kMarqueeStartPause + const Duration(milliseconds: 100));
    final overflow =
        tester.getSize(find.text(_long)).width -
        tester.getSize(find.byType(MarqueeText)).width;
    expect(overflow, greaterThan(0));
    // Remount, so the cycle starts again from its rest.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_host());
    final travel = Duration(
      microseconds: (overflow / kMarqueeSpeed * 1e6).round(),
    );

    // Rests at the start first.
    expect(_offset(tester), 0);
    await tester.pump(kMarqueeStartPause ~/ 2);
    expect(_offset(tester), 0);

    // Then moves at a constant speed.
    await tester.pump(kMarqueeStartPause ~/ 2 + const Duration(seconds: 1));
    final first = _offset(tester);
    expect(first, closeTo(-kMarqueeSpeed, 1));
    await tester.pump(const Duration(seconds: 1));
    expect(_offset(tester) - first, closeTo(-kMarqueeSpeed, 1));

    // It ends exactly on the end of the text and rests there.
    await tester.pump(travel - const Duration(seconds: 2));
    expect(_offset(tester), closeTo(-overflow, 0.5));
    await tester.pump(kMarqueeEndPause ~/ 2);
    expect(_offset(tester), closeTo(-overflow, 0.5));

    // Then snaps back to the start and rests again.
    await tester.pump(kMarqueeEndPause);
    expect(_offset(tester), closeTo(0, 0.5));
    await tester.pump(kMarqueeStartPause ~/ 2);
    expect(_offset(tester), closeTo(0, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('right-to-left titles scroll the other way', (tester) async {
    await tester.pumpWidget(_host(direction: TextDirection.rtl));
    await tester.pump(kMarqueeStartPause + const Duration(seconds: 1));

    expect(_offset(tester), greaterThan(0));
  });

  testWidgets('reduced motion keeps one still line with an ellipsis', (
    tester,
  ) async {
    await tester.pumpWidget(_host(reduceMotion: true));

    final text = tester.widget<Text>(find.text(_long));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('the full title is the semantics label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host());

    expect(find.bySemanticsLabel(_long), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel(_long)).label, _long);
    handle.dispose();
  });

  testWidgets('it follows a width change between fitting and scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(width: 1000));
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pumpWidget(_host());
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);

    await tester.pumpWidget(_host(width: 1000));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a muted ticker mode does not tick it', (tester) async {
    await tester.pumpWidget(_host(tickers: false));
    await tester.pump(kMarqueeStartPause + const Duration(seconds: 1));

    expect(_offset(tester), 0);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('it stops while scrolled off screen and resumes in view', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            // Keep the title built while it is off screen.
            child: const Column(
              children: <Widget>[
                SizedBox(width: 120, child: MarqueeText(_long, style: _style)),
                SizedBox(height: 3000),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);

    scroll.jumpTo(2000);
    await tester.pump();
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);

    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('it disposes cleanly while animating', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));

    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });

  group('version-keeping still form', () {
    Rect rect(WidgetTester tester, Finder f) => tester.getRect(f);

    testWidgets('an inactive title ellipsizes the base, never the version', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(text: _versioned, width: 320, active: false),
      );

      final host = rect(tester, find.byType(MarqueeText));
      final suffix = rect(tester, find.text(_suffix));
      expect(suffix.left, greaterThanOrEqualTo(host.left));
      expect(suffix.right, lessThanOrEqualTo(host.right + 0.5));
      expect(_exceeds(tester, find.text(_suffix)), isFalse);
      final base = find.text('A long song title that will not fit');
      expect(_exceeds(tester, base), isTrue);
      expect(rect(tester, base).right, lessThanOrEqualTo(suffix.left + 0.5));
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a fitting title with a version stays one Text', (
      tester,
    ) async {
      await tester.pumpWidget(_host(text: 'Song (Live)', width: 300));
      expect(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Text),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(
        _host(text: 'Song (Live)', width: 300, active: false),
      );
      expect(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Text),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an unbounded width never throws', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UnconstrainedBox(
              child: MarqueeText(_versioned, style: _style, active: false),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UnconstrainedBox(
              child: MarqueeText(_versioned, style: _style),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion shows the same still form', (tester) async {
      await tester.pumpWidget(
        _host(text: _versioned, width: 320, reduceMotion: true),
      );
      expect(find.text(_suffix), findsOneWidget);
      expect(_exceeds(tester, find.text(_suffix)), isFalse);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpAndSettle();
    });

    testWidgets('active: still form at rest, full text while travelling', (
      tester,
    ) async {
      await tester.pumpWidget(_host(text: _versioned, width: 320, passes: 1));

      // The start pause shows the version.
      await tester.pump(kMarqueeStartPause ~/ 2);
      expect(find.text(_suffix), findsOneWidget);
      expect(_offset(tester), 0);

      await tester.pump(kMarqueeStartPause ~/ 2 + const Duration(seconds: 1));
      expect(_offset(tester), lessThan(0));
      expect(find.text(_suffix), findsNothing);

      await tester.pumpAndSettle();
      expect(find.text(_suffix), findsOneWidget);
      expect(_exceeds(tester, find.text(_suffix)), isFalse);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('the full title is one semantics node', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(text: _versioned, width: 320, active: false),
      );

      expect(find.bySemanticsLabel(_versioned), findsOneWidget);
      expect(find.bySemanticsLabel(_suffix), findsNothing);
      expect(find.bySemanticsLabel(' (Radio Edit)'), findsNothing);
      handle.dispose();
    });

    testWidgets('an Arabic title keeps its version at the visual left end', (
      tester,
    ) async {
      const title = 'عنوان أغنية طويل جدا لا يتسع في هذا العرض (ريمكس)';
      await tester.pumpWidget(
        _host(
          text: title,
          width: 300,
          active: false,
          direction: TextDirection.rtl,
        ),
      );
      final suffix = rect(tester, find.text(' (ريمكس)'));
      final base = rect(
        tester,
        find.text('عنوان أغنية طويل جدا لا يتسع في هذا العرض'),
      );
      expect(suffix.center.dx, lessThan(base.center.dx));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a Latin title in an RTL ambient keeps its version right', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          text: _versioned,
          width: 320,
          active: false,
          direction: TextDirection.rtl,
        ),
      );
      final suffix = rect(tester, find.text(_suffix));
      final base = rect(
        tester,
        find.text('A long song title that will not fit'),
      );
      expect(suffix.center.dx, greaterThan(base.center.dx));
    });

    testWidgets('a Latin title with an Arabic version stays left to right', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(text: 'A long song (ريمكس)', width: 200, active: false),
      );
      final suffix = rect(tester, find.text(' (ريمكس)'));
      final base = rect(tester, find.text('A long song'));
      expect(suffix.center.dx, greaterThan(base.center.dx));
    });

    testWidgets('a suffix wider than 55 percent gives one plain ellipsis', (
      tester,
    ) async {
      const title = 'Song (A remix with a really very long descriptive name)';
      await tester.pumpWidget(_host(text: title, width: 200, active: false));

      final texts = find.descendant(
        of: find.byType(MarqueeText),
        matching: find.byType(Text),
      );
      expect(texts, findsOneWidget);
      expect(tester.widget<Text>(texts).data, title);
      expect(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Row),
        ),
        findsNothing,
      );
      expect(_exceeds(tester, texts), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a credit suffix never splits', (tester) async {
      const title = 'Dearly Beloved (From "Kingdom Hearts")';
      await tester.pumpWidget(_host(text: title, width: 181, active: false));

      final texts = find.descendant(
        of: find.byType(MarqueeText),
        matching: find.byType(Text),
      );
      expect(texts, findsOneWidget);
      expect(tester.widget<Text>(texts).data, title);
      expect(_exceeds(tester, texts), isTrue);
      expect(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Row),
        ),
        findsNothing,
      );
    });

    testWidgets('a short tag under 55 percent stays pinned', (tester) async {
      await tester.pumpWidget(
        _host(
          text: 'Dearly Beloved Reprise (Radio Edit)',
          width: 320,
          active: false,
        ),
      );

      final suffix = find.text(' (Radio Edit)');
      expect(suffix, findsOneWidget);
      expect(_exceeds(tester, suffix), isFalse);
      final host = rect(tester, find.byType(MarqueeText));
      expect(rect(tester, suffix).right, lessThanOrEqualTo(host.right + 0.5));
    });

    testWidgets('a short credit under 55 percent still gives one plain Text', (
      tester,
    ) async {
      const title = 'A long song title that will not fit (feat. X)';
      await tester.pumpWidget(_host(text: title, width: 320, active: false));

      final texts = find.descendant(
        of: find.byType(MarqueeText),
        matching: find.byType(Text),
      );
      expect(texts, findsOneWidget);
      expect(tester.widget<Text>(texts).data, title);
      expect(_exceeds(tester, texts), isTrue);
      expect(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Row),
        ),
        findsNothing,
      );
    });

    testWidgets('only the last suffix of a title is tested for a credit', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          text: 'A very long song title (feat. X) (Remix)',
          width: 200,
          active: false,
        ),
      );
      expect(find.text(' (Remix)'), findsOneWidget);
      expect(_exceeds(tester, find.text(' (Remix)')), isFalse);
      expect(
        _exceeds(tester, find.text('A very long song title (feat. X)')),
        isTrue,
      );
    });

    testWidgets(
      'at text scale 1.3 a suffix over the share gives a plain Text',
      (tester) async {
        await tester.pumpWidget(
          _host(text: _versioned, width: 320, active: false),
        );
        expect(find.text(_suffix), findsOneWidget);

        await tester.pumpWidget(
          _host(text: _versioned, width: 320, active: false, textScale: 1.3),
        );
        final texts = find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Text),
        );
        expect(texts, findsOneWidget);
        expect(tester.widget<Text>(texts).data, _versioned);
        expect(_exceeds(tester, texts), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a credit on an RTL title stays one plain Text', (
      tester,
    ) async {
      const title = 'عنوان أغنية طويل جدا لا يتسع في هذا العرض (feat. X)';
      await tester.pumpWidget(
        _host(
          text: title,
          width: 300,
          active: false,
          direction: TextDirection.rtl,
        ),
      );
      final texts = find.descendant(
        of: find.byType(MarqueeText),
        matching: find.byType(Text),
      );
      expect(texts, findsOneWidget);
      expect(tester.widget<Text>(texts).data, title);
      expect(_exceeds(tester, texts), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('centred text that fits is centred', (tester) async {
      await tester.pumpWidget(
        _host(text: 'Short', width: 200, textAlign: TextAlign.center),
      );
      final host = rect(tester, find.byType(MarqueeText));
      expect(
        rect(tester, find.text('Short')).center.dx,
        closeTo(host.center.dx, 1),
      );
    });

    testWidgets('strutStyle sets the line height in both forms', (
      tester,
    ) async {
      const strut = StrutStyle(fontSize: 13, height: 3, forceStrutHeight: true);
      await tester.pumpWidget(
        _host(text: _versioned, width: 320, active: false, strutStyle: strut),
      );
      expect(tester.getSize(find.byType(MarqueeText)).height, closeTo(39, 0.5));
      await tester.pumpWidget(
        _host(text: _versioned, width: 320, strutStyle: strut),
      );
      expect(tester.getSize(find.byType(MarqueeText)).height, closeTo(39, 0.5));
      await tester.pump(kMarqueeStartPause + const Duration(seconds: 1));
      expect(tester.getSize(find.byType(MarqueeText)).height, closeTo(39, 0.5));
    });

    testWidgets('changing passes restarts them', (tester) async {
      await tester.pumpWidget(_host(passes: 1));
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(_host(passes: 2));
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('an inactive title without a version is one plain Text', (
      tester,
    ) async {
      await tester.pumpWidget(_host(active: false));
      final texts = find.descendant(
        of: find.byType(MarqueeText),
        matching: find.byType(Text),
      );
      expect(texts, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(LayoutBuilder),
        ),
        findsNothing,
      );
      expect(_exceeds(tester, texts), isTrue);
    });
  });

  group('two lines', () {
    final texts = find.descendant(
      of: find.byType(MarqueeText),
      matching: find.byType(Text),
    );

    testWidgets('a title that fits in two lines is one plain Text', (
      tester,
    ) async {
      const title = 'A long song title that wraps once (Radio Edit)';
      await tester.pumpWidget(
        _host(text: title, width: 400, maxLines: 2, active: true),
      );
      final text = tester.widget<Text>(texts);
      expect(text.data, title);
      expect(text.maxLines, 2);
      expect(_exceeds(tester, texts), isFalse);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('never scrolls, even when active', (tester) async {
      await tester.pumpWidget(_host(width: 120, maxLines: 2));
      await tester.pump(kMarqueeStartPause + const Duration(seconds: 1));
      expect(_scrollers, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a long base keeps its version whole at the end of line 2', (
      tester,
    ) async {
      const title =
          'A very long song title that cannot possibly fit in two short '
          'lines of this narrow box (Radio Edit)';
      await tester.pumpWidget(_host(text: title, width: 400, maxLines: 2));
      final shown = tester.widget<Text>(texts).data!;
      expect(shown.endsWith('… (Radio Edit)'), isTrue, reason: shown);
      expect('…'.allMatches(shown), hasLength(1));
      expect(_exceeds(tester, texts), isFalse);
      expect(tester.getSize(texts).height, lessThan(2.5 * 13 * 1.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a credit ends line 2 in one plain ellipsis', (tester) async {
      const title = 'Dearly Beloved (From "Kingdom Hearts" and more things)';
      await tester.pumpWidget(_host(text: title, width: 130, maxLines: 2));
      expect(texts, findsOneWidget);
      expect(tester.widget<Text>(texts).data, title);
      expect(_exceeds(tester, texts), isTrue);
    });

    testWidgets('a version over 55 percent of the width gives one ellipsis', (
      tester,
    ) async {
      const title = 'Song (A remix with a really very long descriptive name)';
      await tester.pumpWidget(_host(text: title, width: 100, maxLines: 2));
      expect(tester.widget<Text>(texts).data, title);
    });

    testWidgets('a grapheme cluster is never split', (tester) async {
      const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';
      final base = List.filled(30, family).join();
      await tester.pumpWidget(
        _host(text: '$base (Radio Edit)', width: 400, maxLines: 2),
      );
      final shown = tester.widget<Text>(texts).data!;
      final kept = shown.substring(0, shown.indexOf('…'));
      expect(kept, isNotEmpty);
      expect(kept.characters.every((c) => c == family), isTrue, reason: kept);
      expect(shown.endsWith('… (Radio Edit)'), isTrue);
    });

    testWidgets('the full title is one semantics node', (tester) async {
      final handle = tester.ensureSemantics();
      const title =
          'A very long song title that cannot possibly fit in two short '
          'lines of this narrow box (Radio Edit)';
      await tester.pumpWidget(_host(text: title, width: 400, maxLines: 2));
      expect(find.bySemanticsLabel(title), findsOneWidget);
      handle.dispose();
    });

    testWidgets('an Arabic title keeps its version last in a right-to-left run', (
      tester,
    ) async {
      const title =
          'عنوان أغنية طويل جدا لا يتسع في هذا العرض الضيق أبدا ولا في سطرين (ريمكس)';
      await tester.pumpWidget(
        _host(
          text: title,
          width: 400,
          maxLines: 2,
          direction: TextDirection.ltr,
        ),
      );
      final text = tester.widget<Text>(texts);
      expect(text.data!.endsWith('… (ريمكس)'), isTrue, reason: text.data);
      expect(text.textDirection, TextDirection.rtl);
    });

    testWidgets('a Latin title in an RTL ambient keeps its version right', (
      tester,
    ) async {
      const title =
          'A very long song title that cannot possibly fit in two short '
          'lines of this narrow box (Radio Edit)';
      await tester.pumpWidget(
        _host(
          text: title,
          width: 400,
          maxLines: 2,
          direction: TextDirection.rtl,
        ),
      );
      final text = tester.widget<Text>(texts);
      expect(text.data!.endsWith('… (Radio Edit)'), isTrue);
      expect(text.textDirection, TextDirection.ltr);
    });

    testWidgets('a Latin title with an Arabic version stays left to right', (
      tester,
    ) async {
      const title =
          'A very long song title that cannot possibly fit in two short '
          'lines of this narrow box (ريمكس)';
      await tester.pumpWidget(_host(text: title, width: 400, maxLines: 2));
      final text = tester.widget<Text>(texts);
      expect(text.data!.endsWith('… (ريمكس)'), isTrue);
      expect(text.textDirection, TextDirection.ltr);
    });
  });
  group('Keep Song Versions Visible off', () {
    const long =
        'A very long song title that cannot possibly fit in two short '
        'lines of this narrow box (Radio Edit)';
    final texts = find.descendant(
      of: find.byType(MarqueeText),
      matching: find.byType(Text),
    );
    final rows = find.descendant(
      of: find.byType(MarqueeText),
      matching: find.byType(Row),
    );

    testWidgets('one line: one plain ellipsis, no Row, the full title', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(text: _versioned, width: 320, active: false, keepVersion: false),
      );
      final text = tester.widget<Text>(texts);
      expect(text.data, _versioned);
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(rows, findsNothing);
      expect(_exceeds(tester, texts), isTrue);
    });

    testWidgets('two lines: one plain ellipsis over the full title', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(text: long, width: 400, maxLines: 2, keepVersion: false),
      );
      final text = tester.widget<Text>(texts);
      expect(text.data, long);
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(rows, findsNothing);
      expect(texts, findsOneWidget);
    });

    testWidgets('a scrolling title still scrolls and rests as plain text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(text: _versioned, width: 320, keepVersion: false),
      );
      expect(rows, findsNothing);
      await tester.pump(kMarqueeStartPause + const Duration(seconds: 1));
      expect(_scrollers, findsOneWidget);
    });

    testWidgets('on keeps the version whole, as does a missing scope', (
      tester,
    ) async {
      for (final keep in <bool?>[true, null]) {
        await tester.pumpWidget(
          _host(text: _versioned, width: 320, active: false, keepVersion: keep),
        );
        expect(find.text(_suffix), findsOneWidget, reason: '$keep');
        expect(rows, findsOneWidget);
        await tester.pumpWidget(
          _host(text: long, width: 400, maxLines: 2, keepVersion: keep),
        );
        expect(tester.widget<Text>(texts).data, endsWith('… (Radio Edit)'));
      }
    });

    testWidgets('toggling the setting rebuilds an existing title', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(text: _versioned, width: 320, active: false, keepVersion: true),
      );
      expect(rows, findsOneWidget);
      await tester.pumpWidget(
        _host(text: _versioned, width: 320, active: false, keepVersion: false),
      );
      expect(rows, findsNothing);
    });
  });
}
