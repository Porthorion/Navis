import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/marquee_text.dart';

const _long = 'A deliberately very long album title that cannot fit in a card';
const _style = TextStyle(fontSize: 13);

Widget _host({
  String text = _long,
  double width = 120,
  bool reduceMotion = false,
  TextDirection direction = TextDirection.ltr,
  bool tickers = true,
  int? passes,
}) => MaterialApp(
  home: Directionality(
    textDirection: direction,
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: TickerMode(
        enabled: tickers,
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: MarqueeText(text, style: _style, passes: passes),
            ),
          ),
        ),
      ),
    ),
  ),
);

Transform _scroller(WidgetTester tester) => tester.widget<Transform>(
  find.descendant(
    of: find.byType(MarqueeText),
    matching: find.byType(Transform),
  ),
);

double _offset(WidgetTester tester) =>
    _scroller(tester).transform.getTranslation().x;

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
    final overflow =
        tester.getSize(find.text(_long)).width -
        tester.getSize(find.byType(MarqueeText)).width;
    expect(overflow, greaterThan(0));
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
}
