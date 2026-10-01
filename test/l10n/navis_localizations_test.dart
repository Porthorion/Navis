import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';

void main() {
  for (final language in ['en', 'ar']) {
    testWidgets('modern design delegates load for $language', (tester) async {
      late BuildContext localizedContext;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('en'), Locale('ar')],
          // Navis currently translates application strings only into English.
          // Arabic exercises the design libraries' RTL delegates independently.
          localizationsDelegates: navisLocalizationsDelegates.where(
            (delegate) =>
                language == 'en' || delegate != AppLocalizations.delegate,
          ),
          home: Builder(
            builder: (context) {
              localizedContext = context;
              return const Scaffold(body: Text('Navis'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      if (language == 'en') {
        expect(AppLocalizations.of(localizedContext), isNotNull);
      }
      expect(MaterialLocalizations.of(localizedContext), isNotNull);
      expect(CupertinoLocalizations.of(localizedContext), isNotNull);
      expect(
        Directionality.of(localizedContext),
        language == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
