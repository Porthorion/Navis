import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/cover_art_viewer.dart';
import 'package:navis/src/providers/app_providers.dart';

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
  await tester.pump(const Duration(milliseconds: 200));
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
    expect(find.byTooltip('Close'), findsOneWidget);
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

  testWidgets(
    'full-resolution viewer art replaces its preview only when ready',
    (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subsonicApiProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            home: CoverArtViewerScreen(
              coverArtId: 'cover-1',
              heroTag: 'cover-hero',
              previewSize: 320,
            ),
          ),
        ),
      );

      expect(find.byTooltip('Close'), findsOneWidget);

      final fullResolution = tester.widget<CoverArtImage>(
        find.byWidgetPredicate(
          (widget) => widget is CoverArtImage && widget.size == 1600,
        ),
      );
      expect(fullResolution.onImageReady, isNotNull);
      expect(fullResolution.useRequestedMemCacheSize, isTrue);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(
                const ValueKey<String>('coverArtViewerFullResolutionLayer'),
              ),
            )
            .opacity,
        0,
      );

      fullResolution.onImageReady!();
      await tester.pump();
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(
                const ValueKey<String>('coverArtViewerFullResolutionLayer'),
              ),
            )
            .opacity,
        1,
      );

      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is CoverArtImage && widget.size == 320,
        ),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is CoverArtImage && widget.size == 1600,
        ),
        findsOneWidget,
      );
    },
  );
}
