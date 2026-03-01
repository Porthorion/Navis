import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/features/search/presentation/search_screen.dart';
import 'package:riverpod/src/framework.dart' show Override;

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
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SearchScreen(),
      ),
    ),
  );
  await tester.pump();
}

FocusNode _searchFocusNode(WidgetTester tester) {
  final textField = tester.widget<TextField>(find.byType(TextField).first);
  return textField.focusNode!;
}

void main() {
  group('SearchScreen focus behavior', () {
    testWidgets(
      'focus request focuses the search bar when player is collapsed',
      (
        tester,
      ) async {
        if (!sqliteAvailable) {
          return;
        }

        final container = _createContainerWithDatabase();
        await _pumpSearchScreen(tester, container);

        expect(_searchFocusNode(tester).hasFocus, isFalse);

        container.read(searchFocusRequestProvider.notifier).increment();
        await tester.pump();
        await tester.pump();

        expect(_searchFocusNode(tester).hasFocus, isTrue);
      },
    );

    testWidgets(
      'expanded player clears focus and blocks refocus until an explicit request',
      (tester) async {
        if (!sqliteAvailable) {
          return;
        }

        final container = _createContainerWithDatabase();
        await _pumpSearchScreen(tester, container);

        container.read(searchFocusRequestProvider.notifier).increment();
        await tester.pump();
        await tester.pump();
        expect(_searchFocusNode(tester).hasFocus, isTrue);

        container.read(playerOverlayStackProvider.notifier).expand();
        await tester.pump();
        await tester.pump();
        expect(_searchFocusNode(tester).hasFocus, isFalse);

        container.read(searchFocusRequestProvider.notifier).increment();
        await tester.pump();
        await tester.pump();
        expect(_searchFocusNode(tester).hasFocus, isFalse);

        container.read(playerOverlayStackProvider.notifier).collapse();
        await tester.pump();
        await tester.pump();
        expect(_searchFocusNode(tester).hasFocus, isFalse);
      },
    );
  });
}
