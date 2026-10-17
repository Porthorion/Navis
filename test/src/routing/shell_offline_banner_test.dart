import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/marquee_text.dart';
import 'package:navis/src/common_widgets/notice_icon_disc.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/routing/shell_offline_banner.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/theme/navis_tokens.dart';

class _Reachability extends ServerReachabilityController {
  @override
  ServerReachabilityState build() =>
      const ServerReachabilityState(status: ServerReachabilityStatus.offline);

  void setStatus(ServerReachabilityStatus status) {
    state = ServerReachabilityState(status: status);
  }
}

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
  test(
    'dismissal survives checking and resets only after confirmed online',
    () {
      final reachability = _Reachability();
      final container = ProviderContainer(
        overrides: [
          serverReachabilityControllerProvider.overrideWith(() => reachability),
        ],
      );
      addTearDown(container.dispose);
      container.listen(shellOfflineBannerDismissedProvider, (_, _) {});
      container.read(shellOfflineBannerDismissedProvider.notifier).dismiss();
      expect(container.read(shellOfflineBannerDismissedProvider), isTrue);
      reachability.setStatus(ServerReachabilityStatus.checking);
      expect(container.read(shellOfflineBannerDismissedProvider), isTrue);
      reachability.setStatus(ServerReachabilityStatus.offline);
      expect(container.read(shellOfflineBannerDismissedProvider), isTrue);
      reachability.setStatus(ServerReachabilityStatus.online);
      expect(container.read(shellOfflineBannerDismissedProvider), isFalse);
      reachability.setStatus(ServerReachabilityStatus.offline);
      expect(container.read(shellOfflineBannerDismissedProvider), isFalse);
    },
  );

  Future<void> pump(
    WidgetTester tester, {
    required bool visible,
    bool compact = false,
    bool disableAnimations = false,
    String message = 'Offline mode',
    double width = 400,
    String? fontFamily,
  }) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverReachabilityControllerProvider.overrideWith(_Reachability.new),
        ],
        child: MaterialApp(
          theme: ThemeData(fontFamily: fontFamily),
          localizationsDelegates: navisLocalizationsDelegates,
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 800),
              padding: const EdgeInsets.only(top: _statusBar),
              viewPadding: const EdgeInsets.only(top: _statusBar),
              disableAnimations: disableAnimations,
            ),
            child: ShellOfflineBannerScope(
              visible: visible,
              compact: compact,
              message: message,
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

  testWidgets('the real offline copy fits a 360dp phone without scrolling', (
    tester,
  ) async {
    final message = lookupAppLocalizations(const Locale('en'))
        .serverOfflineBanner;
    // The test font is fixed-width boxes; measure with the app's real font.
    await (FontLoader(
      navisFontFamily,
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await pump(
      tester,
      visible: true,
      message: message,
      width: 360,
      fontFamily: navisFontFamily,
    );
    await tester.pumpAndSettle();

    final marquee = find.byType(MarqueeText);
    final text = tester.widget<Text>(
      find.descendant(of: marquee, matching: find.byType(Text)),
    );
    final painter = TextPainter(
      text: TextSpan(text: message, style: text.style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final slot = find.ancestor(of: marquee, matching: find.byType(Expanded));
    expect(painter.width, lessThanOrEqualTo(tester.getSize(slot.first).width));
    painter.dispose();
  });

  testWidgets(
    'a message wider than the banner scrolls instead of ending in an ellipsis',
    (tester) async {
      const long =
          'Server unreachable. Playing from downloads and the streaming cache '
          'until it is back.';
      await pump(tester, visible: true, message: long);
      // The marquee never settles; let the banner finish arriving.
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(MarqueeText), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.data == long &&
              widget.overflow == TextOverflow.ellipsis,
        ),
        findsNothing,
      );
      expect(find.bySemanticsLabel(long), findsOneWidget);
    },
  );

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

  testWidgets('the banner is a tile strip with a warning disc', (tester) async {
    await pump(tester, visible: true);
    await tester.pumpAndSettle();

    final context = tester.element(banner);
    final tokens = NavisTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final disc = tester.widget<NoticeIconDisc>(find.byType(NoticeIconDisc));
    expect(disc.size, 32);
    expect(disc.fill, tokens.quietWarningContainer);
    expect(disc.ink, tokens.onQuietWarningContainer);
    final tile = tester.widget<Material>(
      find.descendant(of: banner, matching: find.byType(Material)).first,
    );
    expect(tile.color, scheme.surfaceContainerHigh);
    expect(
      (tile.shape! as RoundedRectangleBorder).borderRadius,
      NavisRadius.lgAll,
    );
    final retry = tester.widget<FilledButton>(
      find.byKey(ShellOfflineBanner.retryKey),
    );
    expect(
      retry.style?.backgroundColor?.resolve(<WidgetState>{}),
      scheme.secondaryContainer,
    );
    expect(find.byKey(ShellOfflineBanner.dismissKey), findsOneWidget);
    // Banner plus its vertical inset keeps the documented extent.
    expect(tester.getSize(banner).height, _statusBar + 48);
  });

  final strip = find.byKey(ShellOfflineBanner.stripKey);
  const stripHeight = 24.0;

  testWidgets('compact shows a 24dp strip with the icon and Offline', (
    tester,
  ) async {
    await pump(tester, visible: true, compact: true);
    await tester.pumpAndSettle();

    expect(banner, findsOneWidget);
    expect(strip, findsOneWidget);
    expect(find.byKey(ShellOfflineBanner.retryKey), findsNothing);
    expect(find.byKey(ShellOfflineBanner.dismissKey), findsNothing);
    expect(find.byType(MarqueeText), findsNothing);
    expect(
      find.descendant(of: strip, matching: find.text('Offline')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: strip,
        matching: find.byIcon(Icons.cloud_off_outlined),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(banner).height, _statusBar + stripHeight);
    expect(tester.getSize(strip).height, stripHeight);
    // The strip spans the full width, so the whole width is the hit target.
    expect(tester.getSize(strip).width, tester.getSize(banner).width);
    expect(pageTopPadding(tester), 0);
    expect(tester.getTopLeft(find.byType(_Page)).dy, _statusBar + stripHeight);
    expect(
      tester.getTopLeft(find.byKey(_noticeKey)).dy,
      _statusBar + stripHeight + 12,
    );
  });

  testWidgets('the strip is a labelled button in the quiet warning roles', (
    tester,
  ) async {
    await pump(tester, visible: true, compact: true);
    await tester.pumpAndSettle();

    final tokens = NavisTokens.of(tester.element(strip));
    final material = tester.widget<Material>(strip);
    expect(material.color, tokens.quietWarningContainer);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.cloud_off_outlined)).color,
      tokens.onQuietWarningContainer,
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(of: strip, matching: find.text('Offline')),
          )
          .style
          ?.color,
      tokens.onQuietWarningContainer,
    );
    final handle = tester.ensureSemantics();
    final semantics = tester.getSemantics(strip);
    expect(semantics.label, 'Offline. Retrying…');
    expect(semantics.flagsCollection.isButton, isTrue);
    handle.dispose();
  });

  testWidgets('tapping anywhere on the strip expands the banner again', (
    tester,
  ) async {
    await pump(tester, visible: true, compact: true);
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(strip));
    container.read(shellOfflineBannerDismissedProvider.notifier).dismiss();

    // Far from the icon and text, still the strip.
    await tester.tapAt(tester.getTopLeft(strip) + const Offset(4, 12));
    await tester.pump(const Duration(seconds: 1));
    expect(container.read(shellOfflineBannerDismissedProvider), isFalse);
    container.read(shellOfflineBannerDismissedProvider.notifier).dismiss();
    await tester.tapAt(tester.getTopRight(strip) + const Offset(-4, 12));
    await tester.pump(const Duration(seconds: 1));
    expect(container.read(shellOfflineBannerDismissedProvider), isFalse);
  });

  testWidgets('the banner collapses into the strip and grows back', (
    tester,
  ) async {
    await pump(tester, visible: true);
    await tester.pumpAndSettle();
    expect(tester.getSize(banner).height, _statusBar + 48);
    expect(strip, findsNothing);

    await pump(tester, visible: true, compact: true);
    var previous = tester.getSize(banner).height;
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final height = tester.getSize(banner).height;
      expect(height, lessThanOrEqualTo(previous + 0.001));
      expect(height, greaterThanOrEqualTo(_statusBar + stripHeight));
      previous = height;
      expectNoticeFollowsBanner(tester);
    }
    await tester.pumpAndSettle();
    expect(tester.getSize(banner).height, _statusBar + stripHeight);
    expect(strip, findsOneWidget);
    expect(find.byKey(ShellOfflineBanner.retryKey), findsNothing);
    expectNoticeFollowsBanner(tester);

    await pump(tester, visible: true);
    previous = tester.getSize(banner).height;
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final height = tester.getSize(banner).height;
      expect(height, greaterThanOrEqualTo(previous - 0.001));
      expect(height, lessThanOrEqualTo(_statusBar + 48));
      previous = height;
      expectNoticeFollowsBanner(tester);
    }
    await tester.pumpAndSettle();
    expect(tester.getSize(banner).height, _statusBar + 48);
    expect(strip, findsNothing);
    expect(find.byKey(ShellOfflineBanner.retryKey), findsOneWidget);
  });

  testWidgets('the strip goes away quietly when back online', (tester) async {
    await pump(tester, visible: true, compact: true);
    await tester.pumpAndSettle();
    await pump(tester, visible: false, compact: true);
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expectNoticeFollowsBanner(tester);
    }
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(strip, findsNothing);
    expect(pageTopPadding(tester), _statusBar);
    expect(tester.getTopLeft(find.byType(_Page)).dy, 0);
  });

  testWidgets('with reduced motion the strip replaces the banner at once', (
    tester,
  ) async {
    await pump(tester, visible: true, disableAnimations: true);
    await pump(tester, visible: true, compact: true, disableAnimations: true);
    await tester.pump();
    expect(strip, findsOneWidget);
    expect(find.byKey(ShellOfflineBanner.retryKey), findsNothing);
    expect(tester.getSize(banner).height, _statusBar + stripHeight);
    expectNoticeFollowsBanner(tester);
  });
}
