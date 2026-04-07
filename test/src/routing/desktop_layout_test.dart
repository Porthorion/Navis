import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';

void main() {
  test('resolveDesktopLayoutClass uses expected breakpoints', () {
    expect(
      resolveDesktopLayoutClass(959),
      DesktopLayoutClass.compactDesktop,
    );
    expect(
      resolveDesktopLayoutClass(1200),
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
    'resolveAdaptiveShellMode returns compact-wide for AAOS car screen (16:9 landscape)',
    () {
      // Android Automotive OS emulator: 1408×792dp, aspect ratio ≈ 1.78.
      expect(
        resolveAdaptiveShellMode(
          desktopRuntime: false,
          viewportSize: const Size(1408, 792),
          safePadding: EdgeInsets.zero,
        ),
        AdaptiveShellMode.compactWideLandscape,
      );
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

  test('resolveAdaptiveContext keeps medium desktop window on bottom nav', () {
    final context = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(700, 1000),
      safePadding: EdgeInsets.zero,
    );

    expect(context.desktopRuntime, isTrue);
    expect(context.useDesktopShell, isFalse);
    expect(context.useRailNavigation, isFalse);
    expect(context.adaptiveShellMode, AdaptiveShellMode.phoneBottomNav);
  });

  test('resolveAdaptiveContext uses rail at tablet-expanded widths', () {
    final context = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(840, 1000),
      safePadding: EdgeInsets.zero,
    );

    expect(context.useDesktopShell, isFalse);
    expect(context.useStandardRailNavigation, isTrue);
    expect(context.useRailNavigation, isTrue);
    expect(context.adaptiveShellMode, AdaptiveShellMode.standardRail);
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

  test('resolveAdaptiveContext keeps compact-wide fallback behavior', () {
    final context = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(900, 420),
      safePadding: EdgeInsets.zero,
    );

    expect(context.useDesktopShell, isFalse);
    expect(context.useCompactWideLandscape, isTrue);
    expect(context.adaptiveShellMode, AdaptiveShellMode.compactWideLandscape);
  });

  test('focus player preset resolves to compact-wide landscape', () {
    final context = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: DesktopWindowController.focusDefaultSize,
      safePadding: EdgeInsets.zero,
    );

    expect(context.useDesktopShell, isFalse);
    expect(context.useCompactWideLandscape, isTrue);
  });

  test(
    'normal desktop minimum keeps desktop shell disabled at narrow width',
    () {
      final context = resolveAdaptiveContext(
        desktopRuntime: true,
        viewportSize: DesktopWindowController.normalMinSize,
        safePadding: EdgeInsets.zero,
      );

      expect(context.useDesktopShell, isFalse);
      expect(context.adaptiveShellMode, AdaptiveShellMode.phoneBottomNav);
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
