import 'package:flutter_test/flutter_test.dart';
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

  test('desktop ui build default constant is deterministic', () {
    expect(kDesktopUiV1BuildDefault, isA<bool>());
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
}
