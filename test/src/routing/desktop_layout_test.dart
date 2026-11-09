import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';

void main() {
  test('desktop resolver matrix keeps height and width gates stable', () {
    const cases = <(Size, bool)>[
      (Size(480, 320), false),
      (Size(720, 405), false),
      (Size(799, 599), false),
      (Size(800, 600), true),
      (Size(1008, 640), true),
      (Size(1366, 768), true),
      (Size(1600, 900), true),
      (Size(3440, 600), true),
      (Size(799, 1200), false),
      (Size(3440, 599), false),
    ];
    for (final entry in cases) {
      expect(
        supportsDesktopView(entry.$1),
        entry.$2,
        reason: 'viewport ${entry.$1}',
      );
    }
  });

  test('Mini Player resolver enforces its complete minimum viewport', () {
    expect(supportsMiniPlayer(const Size(559, 360)), isFalse);
    expect(supportsMiniPlayer(const Size(560, 359)), isFalse);
    expect(supportsMiniPlayer(const Size(560, 360)), isTrue);
    expect(supportsMiniPlayer(const Size(720, 405)), isTrue);
  });

  test('resolveDesktopLayoutClass uses expected breakpoints', () {
    expect(resolveDesktopLayoutClass(1007), DesktopLayoutClass.compactDesktop);
    expect(resolveDesktopLayoutClass(1008), DesktopLayoutClass.standardDesktop);
    expect(resolveDesktopLayoutClass(1599), DesktopLayoutClass.standardDesktop);
    expect(
      resolveDesktopLayoutClass(1600),
      DesktopLayoutClass.ultraWideDesktop,
    );
  });

  test('resolveDesktopHeightClass bands the window height', () {
    expect(resolveDesktopHeightClass(600), DesktopHeightClass.short);
    expect(resolveDesktopHeightClass(759), DesktopHeightClass.short);
    expect(resolveDesktopHeightClass(760), DesktopHeightClass.regular);
    expect(resolveDesktopHeightClass(959), DesktopHeightClass.regular);
    expect(resolveDesktopHeightClass(960), DesktopHeightClass.tall);
    expect(resolveDesktopHeightClass(2160), DesktopHeightClass.tall);
    expect(DesktopHeightClass.regular.pick(short: 1, regular: 2, tall: 3), 2);
  });

  test('resolveAdaptiveLayoutClass uses expected breakpoints', () {
    expect(resolveAdaptiveLayoutClass(599), AdaptiveLayoutClass.phoneCompact);
    expect(resolveAdaptiveLayoutClass(600), AdaptiveLayoutClass.tabletMedium);
    expect(resolveAdaptiveLayoutClass(839), AdaptiveLayoutClass.tabletMedium);
    expect(resolveAdaptiveLayoutClass(840), AdaptiveLayoutClass.tabletExpanded);
  });

  test(
    'resolveAdaptiveShellMode returns compact mode for tight phone landscape',
    () {
      expect(
        resolveAdaptiveShellMode(
          desktopRuntime: false,
          viewportSize: const Size(900, 420),
          safePadding: EdgeInsets.zero,
        ),
        AdaptiveShellMode.compactWideLandscape,
      );
    },
  );

  test('resolveAdaptiveShellMode returns rail for taller phone landscape', () {
    expect(
      resolveAdaptiveShellMode(
        desktopRuntime: false,
        viewportSize: const Size(900, 620),
        safePadding: EdgeInsets.zero,
      ),
      AdaptiveShellMode.standardRail,
    );
  });

  test(
    'resolveAdaptiveShellMode keeps the standard rail for 16:9 tablet sizes',
    () {
      // Height, not aspect ratio, decides the compact rail: a 16:9 tablet
      // (or a same-sized car display) is tall enough for the standard rail.
      for (final size in const <Size>[Size(1280, 720), Size(1408, 792)]) {
        expect(
          resolveAdaptiveShellMode(
            desktopRuntime: false,
            viewportSize: size,
            safePadding: EdgeInsets.zero,
          ),
          AdaptiveShellMode.standardRail,
          reason: '$size',
        );
      }
    },
  );

  test('resolveAdaptiveShellMode keeps standardRail for tablet-like aspect ratios (≤1.65)', () {
    // 4:3-ish tablet landscape: aspect ratio ≈ 1.43, should stay on rail.
    expect(
      resolveAdaptiveShellMode(
        desktopRuntime: false,
        viewportSize: const Size(1366, 955),
        safePadding: EdgeInsets.zero,
      ),
      AdaptiveShellMode.standardRail,
    );
  });

  group('I28 short landscape phones use the compact wide shell', () {
    const compact = AdaptiveShellMode.compactWideLandscape;
    const bottomNav = AdaptiveShellMode.phoneBottomNav;
    const rail = AdaptiveShellMode.standardRail;
    const sideStrip = AdaptiveShellMode.sideStripNav;

    // (size, padding as the device reports it, expected mode)
    const cases = <(Size, EdgeInsets, AdaptiveShellMode)>[
      // Short and at least 600 wide: compact wide, whatever the width.
      (Size(667, 375), EdgeInsets.zero, compact), // iPhone SE
      (Size(812, 375), EdgeInsets.fromLTRB(44, 0, 44, 21), compact),
      (Size(780, 360), EdgeInsets.only(left: 48), compact), // 3-button nav
      (Size(678, 466), EdgeInsets.only(bottom: 118), compact), // strip bottom
      (Size(678, 466), EdgeInsets.only(top: 84, bottom: 34), compact),
      (Size(797, 411), EdgeInsets.zero, compact), // Pixel Fold folded
      (Size(844, 390), EdgeInsets.fromLTRB(47, 0, 47, 21), compact),
      (Size(932, 430), EdgeInsets.fromLTRB(59, 0, 59, 21), compact),
      (Size(900, 420), EdgeInsets.zero, compact),
      // Boundaries: the rail fits at 480 high, not at 479; 600 wide is the
      // smallest compact wide window.
      (Size(700, 479), EdgeInsets.zero, compact),
      (Size(700, 480), EdgeInsets.zero, bottomNav),
      (Size(600, 400), EdgeInsets.zero, compact),
      (Size(599, 400), EdgeInsets.zero, bottomNav),
      // An 800x480 car head unit with no insets: the rail fits.
      (Size(800, 480), EdgeInsets.zero, bottomNav),
      // Too narrow for the rail, or the rail fits: bottom navigation.
      (Size(560, 400), EdgeInsets.zero, bottomNav),
      (Size(700, 520), EdgeInsets.zero, bottomNav),
      (Size(375, 667), EdgeInsets.zero, bottomNav),
      // The folded Duo cover: the side strip now hosts the navigation (I29).
      (Size(466, 678), EdgeInsets.fromLTRB(0, 0, 84, 34), sideStrip),
      // Tall enough for the standard rail.
      (Size(900, 620), EdgeInsets.zero, rail),
      (Size(1280, 720), EdgeInsets.zero, rail),
      (Size(1366, 955), EdgeInsets.zero, rail),
    ];

    test('resolves the mode matrix by size and insets', () {
      for (final (size, padding, expected) in cases) {
        expect(
          resolveAdaptiveShellMode(
            desktopRuntime: false,
            viewportSize: size,
            safePadding: padding,
          ),
          expected,
          reason: '$size $padding',
        );
      }
    });

    test('a desktop runtime always keeps the standard rail', () {
      expect(
        resolveAdaptiveShellMode(
          desktopRuntime: true,
          viewportSize: const Size(667, 375),
          safePadding: EdgeInsets.zero,
        ),
        rail,
      );
    });

    testWidgets('the keyboard does not flip the mode (viewPadding decides)', (
      tester,
    ) async {
      // 700x500 sits on the rail-fit boundary: 500 - 34 - 44 = 422 < 436, but
      // with the home indicator dropped by the keyboard it would be 456.
      for (final size in const <Size>[Size(678, 466), Size(700, 500)]) {
        AdaptiveContext? resolved;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: size,
              padding: EdgeInsets.zero,
              viewPadding: const EdgeInsets.only(bottom: 34),
              viewInsets: const EdgeInsets.only(bottom: 200),
            ),
            child: Builder(
              builder: (context) {
                resolved = resolveAdaptiveContextFor(
                  context,
                  desktopRuntimeOverride: false,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(resolved!.useCompactWideLandscape, isTrue, reason: '$size');
      }
    });
  });

  group('I29 a wide side strip hosts the navigation pill', () {
    const sideStrip = AdaptiveShellMode.sideStripNav;
    const bottomNav = AdaptiveShellMode.phoneBottomNav;

    AdaptiveShellMode resolve(
      Size size,
      EdgeInsets padding, {
      bool desktop = false,
    }) => resolveAdaptiveShellMode(
      desktopRuntime: desktop,
      viewportSize: size,
      safePadding: padding,
    );

    test('resolves the strip matrix by size and insets', () {
      const cases = <(String, Size, EdgeInsets, AdaptiveShellMode)>[
        (
          'Duo cover, strip right',
          Size(466, 678),
          EdgeInsets.fromLTRB(0, 0, 84, 34),
          sideStrip,
        ),
        (
          'Duo cover, strip left',
          Size(466, 678),
          EdgeInsets.fromLTRB(84, 0, 0, 34),
          sideStrip,
        ),
        (
          'inset exactly 48',
          Size(466, 678),
          EdgeInsets.fromLTRB(0, 0, 48, 34),
          sideStrip,
        ),
        (
          'inset 47 is too narrow',
          Size(466, 678),
          EdgeInsets.fromLTRB(0, 0, 47, 34),
          bottomNav,
        ),
        (
          'iPhone 16',
          Size(393, 852),
          EdgeInsets.only(top: 59, bottom: 34),
          bottomNav,
        ),
        ('iPhone SE', Size(375, 667), EdgeInsets.zero, bottomNav),
        (
          'too short landscape',
          Size(466, 440),
          EdgeInsets.fromLTRB(0, 0, 84, 0),
          bottomNav,
        ),
        (
          'too short portrait',
          Size(400, 450),
          EdgeInsets.fromLTRB(0, 0, 84, 34),
          bottomNav,
        ),
        (
          'Duo unfolded portrait',
          Size(669, 951),
          EdgeInsets.only(bottom: 34),
          bottomNav,
        ),
        (
          'Duo unfolded landscape strip',
          Size(951, 669),
          EdgeInsets.fromLTRB(0, 0, 84, 34),
          AdaptiveShellMode.standardRail,
        ),
        (
          'Duo cover rotated (I28)',
          Size(678, 466),
          EdgeInsets.fromLTRB(0, 0, 84, 34),
          AdaptiveShellMode.compactWideLandscape,
        ),
      ];
      for (final (name, size, padding, expected) in cases) {
        expect(
          resolve(size, padding),
          expected,
          reason: '$name $size $padding',
        );
      }
    });

    test('the height gate is reserve + pill + mini player + 16', () {
      // 168 + 216 + 64 + 16 = 464 above the bottom inset.
      const strip = EdgeInsets.fromLTRB(0, 0, 84, 34);
      expect(resolve(const Size(466, 498), strip), sideStrip);
      expect(resolve(const Size(466, 497), strip), bottomNav);
    });

    test('a desktop runtime keeps the standard rail', () {
      expect(
        resolve(
          const Size(466, 678),
          const EdgeInsets.fromLTRB(0, 0, 84, 34),
          desktop: true,
        ),
        AdaptiveShellMode.standardRail,
      );
    });

    testWidgets('the keyboard does not flip the mode (viewPadding decides)', (
      tester,
    ) async {
      AdaptiveContext? resolved;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(466, 678),
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.fromLTRB(0, 0, 84, 34),
            viewInsets: EdgeInsets.only(bottom: 250),
          ),
          child: Builder(
            builder: (context) {
              resolved = resolveAdaptiveContextFor(
                context,
                desktopRuntimeOverride: false,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolved!.adaptiveShellMode, sideStrip);
      expect(resolved!.useRailNavigation, isFalse);
    });
  });

  test('resolveAdaptiveShellMode keeps medium tablet on bottom nav', () {
    expect(
      resolveAdaptiveShellMode(
        desktopRuntime: false,
        viewportSize: const Size(700, 1000),
        safePadding: EdgeInsets.zero,
      ),
      AdaptiveShellMode.phoneBottomNav,
    );
  });

  test('desktop runtime always resolves to the desktop workspace', () {
    final context = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(700, 1000),
      safePadding: EdgeInsets.zero,
    );

    expect(context.desktopRuntime, isTrue);
    expect(context.useDesktopShell, isTrue);
    expect(context.useRailNavigation, isFalse);
    expect(context.isPhoneFormFactor, isFalse);
  });

  test('compact desktop does not fall back to the tablet rail shell', () {
    final context = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(840, 1000),
      safePadding: EdgeInsets.zero,
    );

    expect(context.useDesktopShell, isTrue);
    expect(context.useStandardRailNavigation, isFalse);
    expect(context.useRailNavigation, isFalse);
    expect(context.desktopLayoutClass, DesktopLayoutClass.compactDesktop);
  });

  test('resolveAdaptiveContext enables desktop shell only at wide widths', () {
    final context = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(1200, 1000),
      safePadding: EdgeInsets.zero,
    );

    expect(context.desktopWide, isTrue);
    expect(context.useDesktopShell, isTrue);
    expect(context.useRailNavigation, isFalse);
  });

  test('resolveAdaptiveInputPolicy enables traversal and escape parity for tablet/desktop', () {
    final tabletContext = resolveAdaptiveContext(
      desktopRuntime: false,
      viewportSize: const Size(840, 1000),
      safePadding: EdgeInsets.zero,
    );
    final tabletPolicy = resolveAdaptiveInputPolicy(
      adaptiveContext: tabletContext,
    );
    expect(tabletPolicy.enableDeterministicTraversal, isTrue);
    expect(tabletPolicy.enableEscapeOverlayPriority, isTrue);
    expect(tabletPolicy.enableDesktopCommandShortcuts, isFalse);
    expect(tabletPolicy.enableDesktopPointerAffordances, isFalse);

    final desktopContext = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(1366, 900),
      safePadding: EdgeInsets.zero,
    );
    final desktopPolicy = resolveAdaptiveInputPolicy(
      adaptiveContext: desktopContext,
    );
    expect(desktopPolicy.enableDeterministicTraversal, isTrue);
    expect(desktopPolicy.enableEscapeOverlayPriority, isTrue);
    expect(desktopPolicy.enableDesktopCommandShortcuts, isTrue);
    expect(desktopPolicy.enableDesktopPointerAffordances, isTrue);
    expect(desktopPolicy.enableSecondaryClickMenus, isTrue);
  });

  test('desktop runtime never uses compact-wide phone fallback behavior', () {
    final context = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(900, 420),
      safePadding: EdgeInsets.zero,
    );

    expect(context.useDesktopShell, isTrue);
    expect(context.useCompactWideLandscape, isFalse);
  });

  test('mini player preset remains classified as a desktop workspace', () {
    final context = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: DesktopWindowController.miniDefaultSize,
      safePadding: EdgeInsets.zero,
    );

    expect(context.useDesktopShell, isTrue);
    expect(context.useCompactWideLandscape, isFalse);
  });

  test('desktop OS minimum remains desktop-only at narrow width', () {
    final context = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: DesktopWindowController.normalMinSize,
      safePadding: EdgeInsets.zero,
    );

    expect(context.useDesktopShell, isTrue);
    expect(context.useRailNavigation, isFalse);
  });

  testWidgets('resolveAdaptiveContextFor prefers scoped context', (
    tester,
  ) async {
    const scoped = AdaptiveContext(
      desktopRuntime: true,
      desktopWide: true,
      desktopLayoutClass: DesktopLayoutClass.standardDesktop,
      adaptiveLayoutClass: AdaptiveLayoutClass.tabletExpanded,
      adaptiveShellMode: AdaptiveShellMode.standardRail,
      isPhoneFormFactor: false,
      useDesktopShell: true,
      useStandardRailNavigation: false,
      useCompactWideLandscape: false,
      useRailNavigation: false,
    );

    late AdaptiveContext resolved;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(599, 1000)),
        child: AdaptiveContextScope(
          adaptiveContext: scoped,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (context) {
                resolved = resolveAdaptiveContextFor(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    expect(resolved.useDesktopShell, isTrue);
    expect(resolved.desktopWide, isTrue);
  });

  testWidgets('resolveAdaptiveContextFor falls back when scope is absent', (
    tester,
  ) async {
    late AdaptiveContext resolved;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1200, 1000)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              resolved = resolveAdaptiveContextFor(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(resolved.desktopRuntime, isDesktopRuntime);
    expect(resolved.useDesktopShell, isTrue);
  });
}
