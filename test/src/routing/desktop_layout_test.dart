import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:navis/src/routing/desktop_layout.dart';

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
