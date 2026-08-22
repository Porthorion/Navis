import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';

void main() {
  testWidgets('desktop uses a bounded download-quality dialog', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1366, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showDownloadQualitySheet(context),
            child: const Text('Choose quality'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose quality'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Download Quality'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });
}
