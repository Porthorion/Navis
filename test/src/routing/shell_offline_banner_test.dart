import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/routing/shell_offline_banner.dart';

class _Page extends StatefulWidget {
  const new();

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

const _noticeKey = ValueKey<String>('notice');
const _statusBar = 24.0;

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool visible,
    bool disableAnimations = false,
  }) {
    return tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(400, 800),
              padding: const EdgeInsets.only(top: _statusBar),
              viewPadding: const EdgeInsets.only(top: _statusBar),
              disableAnimations: disableAnimations,
            ),
            child: ShellOfflineBannerScope(
              visible: visible,
              message: 'Offline mode',
              child: Stack(
                children: <Widget>[
                  const ShellOfflineBannerFrame(child: _Page()),
                  // Stands in for the shell's AppNoticeHost.
                  ShellOfflineBannerExtentBuilder(
                    builder: (context, extent) => Padding(
                      padding: EdgeInsets.only(top: _statusBar + 12 + extent),
                      child: const SizedBox(
                        key: _noticeKey,
                        width: 100,
                        height: 40,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  double pageTopPadding(WidgetTester tester) =>
      MediaQuery.paddingOf(tester.element(find.byType(_Page))).top;

  final banner = find.byKey(ShellOfflineBanner.bannerKey);

  // The banner's bottom edge, or the status bar inset once it has gone.
  double bannerBottom(WidgetTester tester) =>
      banner.evaluate().isEmpty ? _statusBar : tester.getBottomLeft(banner).dy;

  // The notice keeps exactly 12px below the banner on every frame.
  void expectNoticeFollowsBanner(WidgetTester tester) {
    expect(
      tester.getTopLeft(find.byKey(_noticeKey)).dy,
      moreOrLessEquals(bannerBottom(tester) + 12, epsilon: 0.01),
    );
  }

  testWidgets('hands the top inset back only once the banner has gone', (
    tester,
  ) async {
    await pump(tester, visible: true);
    final pageState = tester.state(find.byType(_Page));
    expect(banner, findsOneWidget);
    expect(pageTopPadding(tester), 0);
    expect(tester.getTopLeft(find.byType(_Page)).dy, _statusBar + 48);

    await pump(tester, visible: false);
    await tester.pump(const Duration(milliseconds: 90));
    // Mid-animation the banner still covers the status bar strip.
    expect(banner, findsOneWidget);
    expect(pageTopPadding(tester), 0);
    final midTop = tester.getTopLeft(find.byType(_Page)).dy;
    expect(midTop, greaterThan(_statusBar));
    expect(midTop, lessThan(_statusBar + 48));

    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(pageTopPadding(tester), _statusBar);
    expect(tester.getTopLeft(find.byType(_Page)).dy, 0);

    await pump(tester, visible: true);
    await tester.pumpAndSettle();
    expect(pageTopPadding(tester), 0);
    // Pages keep their state while the banner comes and goes.
    expect(tester.state(find.byType(_Page)), same(pageState));
  });

  testWidgets('notices follow the banner on every frame of both animations', (
    tester,
  ) async {
    await pump(tester, visible: true);
    expectNoticeFollowsBanner(tester);

    await pump(tester, visible: false);
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expectNoticeFollowsBanner(tester);
    }
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expectNoticeFollowsBanner(tester);

    await pump(tester, visible: true);
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expectNoticeFollowsBanner(tester);
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(_noticeKey)).dy, _statusBar + 48 + 12);
  });

  testWidgets('notices follow a banner toggle reversed halfway', (
    tester,
  ) async {
    await pump(tester, visible: true);
    await pump(tester, visible: false);
    await tester.pump(const Duration(milliseconds: 80));
    expectNoticeFollowsBanner(tester);

    await pump(tester, visible: true);
    for (var frame = 0; frame < 14; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expectNoticeFollowsBanner(tester);
    }
    await tester.pumpAndSettle();
    expect(banner, findsOneWidget);
    expectNoticeFollowsBanner(tester);
  });

  testWidgets('with reduced motion the banner and notices move at once', (
    tester,
  ) async {
    await pump(tester, visible: true, disableAnimations: true);
    await pump(tester, visible: false, disableAnimations: true);
    await tester.pump();
    expect(banner, findsNothing);
    expect(pageTopPadding(tester), _statusBar);
    expectNoticeFollowsBanner(tester);

    await pump(tester, visible: true, disableAnimations: true);
    await tester.pump();
    expect(banner, findsOneWidget);
    expect(pageTopPadding(tester), 0);
    expectNoticeFollowsBanner(tester);
  });
}
