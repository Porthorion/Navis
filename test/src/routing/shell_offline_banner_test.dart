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

void main() {
  Future<void> pump(WidgetTester tester, {required bool visible}) {
    return tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(400, 800),
              padding: EdgeInsets.only(top: 24),
              viewPadding: EdgeInsets.only(top: 24),
            ),
            child: ShellOfflineBannerFrame(
              visible: visible,
              message: 'Offline mode',
              child: const _Page(),
            ),
          ),
        ),
      ),
    );
  }

  double pageTopPadding(WidgetTester tester) =>
      MediaQuery.paddingOf(tester.element(find.byType(_Page))).top;

  testWidgets('hands the top inset back only once the banner has gone', (
    tester,
  ) async {
    await pump(tester, visible: true);
    final pageState = tester.state(find.byType(_Page));
    expect(find.byKey(ShellOfflineBanner.bannerKey), findsOneWidget);
    expect(pageTopPadding(tester), 0);
    expect(tester.getTopLeft(find.byType(_Page)).dy, 24 + 48);

    await pump(tester, visible: false);
    await tester.pump(const Duration(milliseconds: 90));
    // Mid-animation the banner still covers the status bar strip.
    expect(find.byKey(ShellOfflineBanner.bannerKey), findsOneWidget);
    expect(pageTopPadding(tester), 0);
    final midTop = tester.getTopLeft(find.byType(_Page)).dy;
    expect(midTop, greaterThan(24));
    expect(midTop, lessThan(24 + 48));

    await tester.pumpAndSettle();
    expect(find.byKey(ShellOfflineBanner.bannerKey), findsNothing);
    expect(pageTopPadding(tester), 24);
    expect(tester.getTopLeft(find.byType(_Page)).dy, 0);

    await pump(tester, visible: true);
    await tester.pumpAndSettle();
    expect(pageTopPadding(tester), 0);
    // Pages keep their state while the banner comes and goes.
    expect(tester.state(find.byType(_Page)), same(pageState));
  });
}
