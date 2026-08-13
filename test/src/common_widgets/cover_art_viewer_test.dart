import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_viewer.dart';

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? pushedRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushedRoute = route;
  }
}

Future<void> _pumpViewerHarness(
  WidgetTester tester, {
  required bool reduceMotion,
  required _RouteObserver observer,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        navigatorObservers: <NavigatorObserver>[observer],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showRemoteArtViewer(
              context,
              artUrl: 'https://example.com/cover.jpg',
            ),
            child: const Text('Open artwork'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open artwork'));
  await tester.pump();
}

void main() {
  testWidgets('art viewer keeps its short fade by default', (tester) async {
    final observer = _RouteObserver();
    await _pumpViewerHarness(
      tester,
      reduceMotion: false,
      observer: observer,
    );

    final route = observer.pushedRoute! as PageRoute<dynamic>;
    expect(route.transitionDuration, const Duration(milliseconds: 170));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 130));
  });

  testWidgets('art viewer opens without fade for reduced motion', (
    tester,
  ) async {
    final observer = _RouteObserver();
    await _pumpViewerHarness(
      tester,
      reduceMotion: true,
      observer: observer,
    );

    final route = observer.pushedRoute! as PageRoute<dynamic>;
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    expect(find.byType(FadeTransition), findsNothing);
  });
}
