import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/data/autoeq_catalogue.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_import_dialogs.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/providers/app_providers.dart';

class _Catalogue extends Mock implements AutoEqCatalogue;

class _FakeIndex extends Fake implements AutoEqIndex {}

class _FakeEntry extends Fake implements AutoEqEntry {}

void main() {
  late _Catalogue catalogue;
  final index = AutoEqIndex(
    revision: 'a' * 40,
    entries: const [
      AutoEqEntry(
        name: 'Test Headphones',
        path: 'lab/Test Headphones',
        measurementSource: 'Lab',
        recommended: true,
      ),
    ],
  );

  setUpAll(() {
    registerFallbackValue(_FakeIndex());
    registerFallbackValue(_FakeEntry());
  });

  setUp(() {
    catalogue = _Catalogue();
    when(catalogue.load).thenAnswer((_) async => index);
    when(catalogue.refresh).thenAnswer((_) async => index);
  });

  Future<void> open(WidgetTester tester, IntegrationPolicy policy) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          autoEqCatalogueProvider.overrideWithValue(catalogue),
          integrationPolicyProvider.overrideWithValue(policy),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: EqAutoEqDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder refreshButton() =>
      find.widgetWithText(TextButton, 'Refresh Catalogue');

  testWidgets('refresh is available while AutoEQ is allowed', (tester) async {
    await open(tester, const IntegrationPolicy());

    expect(tester.widget<TextButton>(refreshButton()).onPressed, isNotNull);
    await tester.tap(refreshButton());
    await tester.pumpAndSettle();
    verify(catalogue.refresh).called(1);
  });

  for (final entry in <String, IntegrationPolicy>{
    'the AutoEQ switch is off': const IntegrationPolicy(
      disabledKeys: {'autoeq.catalogue'},
    ),
    'the AutoEQ service is off': const IntegrationPolicy(
      disabledKeys: {'autoeq'},
    ),
    'the master switch is off': const IntegrationPolicy(masterEnabled: false),
  }.entries) {
    testWidgets('search still works but refresh and download are disabled when '
        '${entry.key}', (tester) async {
      await open(tester, entry.value);

      // The bundled catalogue is still searchable.
      expect(find.text('Test Headphones'), findsOneWidget);
      verify(catalogue.load).called(1);
      expect(tester.widget<TextButton>(refreshButton()).onPressed, isNull);
      expect(
        find.textContaining('turned off in Integrations settings'),
        findsOneWidget,
      );

      await tester.tap(find.text('Test Headphones'));
      await tester.pumpAndSettle();
      verifyNever(catalogue.refresh);
      verifyNever(() => catalogue.download(any(), any()));
    });
  }
}
