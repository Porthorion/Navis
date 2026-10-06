import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/features/search/presentation/search_screen.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../helpers/adaptive_test_harness.dart';
import '../../../helpers/test_database.dart';

ProviderContainer _createContainerWithDatabase({
  List<Override> overrides = const <Override>[],
}) {
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(database, overrides: overrides),
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  return container;
}

Future<void> _pumpSearchScreen(
  WidgetTester tester,
  ProviderContainer container, {
  bool desktopIconsOnly = false,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DesktopNavigationPresentationScope(
          iconsOnly: desktopIconsOnly,
          child: const SearchScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'search screen follows shared adaptive context width matrix on desktop runtime',
    (tester) async {
      if (!sqliteAvailable) {
        return;
      }
      setAdaptiveTestViewport(tester, const Size(599, 1000));
      final container = _createContainerWithDatabase();
      await _pumpSearchScreen(tester, container);

      expect(find.byType(DesktopFrame), findsNothing);
      expect(find.byType(AppBar), findsOneWidget);
      expect(tester.takeException(), isNull);

      final transitions = <({Size size, bool desktopFrame, bool appBar})>[
        (size: const Size(700, 1000), desktopFrame: false, appBar: false),
        (size: const Size(840, 1000), desktopFrame: false, appBar: false),
        (size: const Size(1200, 1000), desktopFrame: true, appBar: false),
        (size: const Size(900, 420), desktopFrame: false, appBar: false),
      ];

      for (final step in transitions) {
        tester.view.physicalSize = step.size;
        await tester.pumpAndSettle();
        expect(
          find.byType(DesktopFrame),
          step.desktopFrame ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(AppBar),
          step.appBar ? findsOneWidget : findsNothing,
        );
        if (step.desktopFrame) {
          expect(find.byType(TextField), findsOneWidget);
          expect(
            find.byKey(const ValueKey<String>('desktopSearchWorkspaceTitle')),
            findsNothing,
          );
          expect(find.byType(DesktopPanel), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }
    },
  );
}
