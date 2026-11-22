import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/check_for_updates_button.dart';
import 'package:navis/src/providers/app_providers.dart';

const _info = UpdateInfo(
  sha256: null,
  size: null,
  tagName: 'v2.0.0',
  htmlUrl: 'https://example.com/release',
  delivery: UpdateDelivery.releasePage,
);

Future<int> _pump(
  WidgetTester tester, {
  UpdateInfo? info,
  AppNoticeController? notices,
}) async {
  var checks = 0;
  const button = Scaffold(body: Center(child: CheckForUpdatesButton()));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWith(
          (ref) => Stream.value(const AppSettingsModel.defaults()),
        ),
        updateProvider.overrideWith((ref) async {
          checks++;
          return info;
        }),
      ],
      child: MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: notices == null
            ? button
            : AppNoticeScope(notifier: notices, child: button),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return checks;
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets('hidden where About hides update controls (iOS)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _pump(tester);
      expect(find.text(l10n.updateCheckTitle), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('tap runs the shared check and opens the update dialog', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await _pump(tester, info: _info);
      await tester.tap(find.text(l10n.updateCheckTitle));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('tap with no update shows the up-to-date notice', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final notices = AppNoticeController();
    addTearDown(notices.dispose);
    try {
      await _pump(tester, notices: notices);
      await tester.tap(find.text(l10n.updateCheckTitle));
      await tester.pumpAndSettle();
      expect(notices.notice?.message, l10n.updateUpToDate);
      notices.dismiss();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
