import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/equalizer/data/autoeq_catalogue.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _Catalogue extends Mock implements AutoEqCatalogue;

void main() {
  testWidgets('AutoEQ discovery fits large text and a mobile keyboard', (
    tester,
  ) async {
    const size = Size(390, 844);
    setAdaptiveTestViewport(tester, size);
    final database = createTestDatabase();
    final catalogue = _Catalogue();
    when(catalogue.load).thenAnswer(
      (_) async => AutoEqIndex(
        revision: 'a' * 40,
        entries: [
          const AutoEqEntry(
            name: 'Headphones',
            path: 'lab/Headphones',
            measurementSource: 'Lab',
            recommended: true,
          ),
        ],
      ),
    );
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          audioHandlerProvider.overrideWithValue(null),
          autoEqCatalogueProvider.overrideWithValue(catalogue),
          eqCapabilitiesProvider.overrideWithValue(EqCapabilities.available),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    await container.read(equalizerProvider.future);
    var keyboard = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              viewInsets: EdgeInsets.only(bottom: keyboard ? 300 : 0),
            ),
            child: AdaptiveContextScope(
              adaptiveContext: resolveAdaptiveContext(
                desktopRuntime: false,
                viewportSize: size,
                safePadding: EdgeInsets.zero,
              ),
              child: child!,
            ),
          ),
          home: const EqualizerScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('eq-preset-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find Headphones in AutoEQ'));

    await tester.pumpAndSettle();
    verify(catalogue.load).called(1);
    await tester.scrollUntilVisible(
      find.text('Headphones'),
      100,
      scrollable: find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    expect(find.text('Headphones'), findsOneWidget);
    keyboard = true;
    tester.element(find.byType(MaterialApp)).markNeedsBuild();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      container.read(equalizerProvider).requireValue.configuration.enabled,
      isFalse,
    );
  }, skip: !sqliteAvailable);
  testWidgets('unavailable backend has explanation and no editable controls', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        eqCapabilitiesProvider.overrideWithValue(EqCapabilities.unavailable),
        audioHandlerProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const EqualizerScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('Equalizer is unavailable with this audio engine.'),
      findsOneWidget,
    );
    expect(find.byType(Slider), findsNothing);
  });
}
