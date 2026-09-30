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
    expect(
      resolveDesktopLayoutClass(1007),
      DesktopLayoutClass.compactDesktop,
    );
    expect(
      resolveDesktopLayoutClass(1008),
      DesktopLayoutClass.standardDesktop,
    );
    expect(
      resolveDesktopLayoutClass(1599),
      DesktopLayoutClass.standardDesktop,
    );
    expect(
      resolveDesktopLayoutClass(1600),
      DesktopLayoutClass.ultraWideDesktop,
    );
  });

  test('resolveAdaptiveLayoutClass uses expected breakpoints', () {
    expect(
      resolveAdaptiveLayoutClass(599),
      AdaptiveLayoutClass.phoneCompact,
    );
    expect(
      resolveAdaptiveLayoutClass(600),
      AdaptiveLayoutClass.tabletMedium,
    );
    expect(
      resolveAdaptiveLayoutClass(839),
      AdaptiveLayoutClass.tabletMedium,
    );
    expect(
      resolveAdaptiveLayoutClass(840),
      AdaptiveLayoutClass.tabletExpanded,
    );
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

  test(
    'resolveAdaptiveShellMode keeps standardRail for tablet-like aspect ratios (≤1.65)',
    () {
      // 4:3-ish tablet landscape: aspect ratio ≈ 1.43, should stay on rail.
      expect(
        resolveAdaptiveShellMode(
          desktopRuntime: false,
          viewportSize: const Size(1366, 955),
          safePadding: EdgeInsets.zero,
        ),
        AdaptiveShellMode.standardRail,
      );
    },
  );

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

  test(
    'resolveAdaptiveInputPolicy enables traversal and escape parity for tablet/desktop',
    () {
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
    },
  );

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

  test(
    'desktop OS minimum remains desktop-only at narrow width',
    () {
      final context = resolveAdaptiveContext(
        desktopRuntime: true,
        viewportSize: DesktopWindowController.normalMinSize,
        safePadding: EdgeInsets.zero,
      );

      expect(context.useDesktopShell, isTrue);
      expect(context.useRailNavigation, isFalse);
    },
  );

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

  testWidgets('resolveAdaptiveInputPolicyFor prefers scoped policy', (
    tester,
  ) async {
    const scopedPolicy = AdaptiveInputPolicy(
      enableDeterministicTraversal: true,
      enableEscapeOverlayPriority: true,
      enableDesktopPointerAffordances: true,
      enableSecondaryClickMenus: true,
      enableDesktopCommandShortcuts: true,
    );
    late AdaptiveInputPolicy resolved;
    await tester.pumpWidget(
      AdaptiveInputPolicyScope(
        policy: scopedPolicy,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              resolved = resolveAdaptiveInputPolicyFor(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(resolved.enableDesktopCommandShortcuts, isTrue);
    expect(resolved.enableSecondaryClickMenus, isTrue);
  });
}
