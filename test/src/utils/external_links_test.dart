import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/utils/external_links.dart';

import '../../helpers/fake_url_launcher.dart';

void main() {
  Future<AppNoticeController> pumpLink(WidgetTester tester, Uri uri) async {
    final controller = AppNoticeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AppNoticeScope(
            notifier: controller,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => openExternalLink(context, uri, label: 'it'),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('opens the link outside Navis', (tester) async {
    final launcher = FakeUrlLauncher.install();
    final controller = await pumpLink(tester, supportEmailUri);

    expect(launcher.launched, <String>['mailto:support@porthorion.com']);
    expect(controller.notice, isNull);
  });

  testWidgets('says so when nothing can open the link', (tester) async {
    FakeUrlLauncher.install().succeeds = false;
    final controller = await pumpLink(
      tester,
      Uri.parse('https://navis.porthorion.com'),
    );

    expect(controller.notice?.message, "Couldn't open it.");
    expect(controller.notice?.level, AppNoticeLevel.error);
  });
}
