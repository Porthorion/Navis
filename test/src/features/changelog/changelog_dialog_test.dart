import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/changelog_dialog.dart';
import 'package:navis/src/features/changelog/presentation/changelog_screen.dart';

void main() {
  testWidgets('bug-fix-only release is labeled clearly', (tester) async {
    const version = ChangelogVersion(
      version: '9.9.9',
      entries: [
        ChangelogEntry(
          'Fixed queued remote playback getting stuck',
          type: ChangelogEntryType.fix,
        ),
      ],
    );
    final router = _createRouter(version);

    await _pumpRouter(tester, router);
    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.changelogDialogBugFixesTitle), findsWidgets);
    expect(find.text(l10n.changelogDialogViewAll), findsOneWidget);
  });

  testWidgets('dialog full changelog action opens About changelog', (
    tester,
  ) async {
    const version = ChangelogVersion(
      version: '9.9.9',
      entries: [
        ChangelogEntry(
          'Added a highlighted change',
          type: ChangelogEntryType.improvement,
        ),
        ChangelogEntry(
          'Fixed queued remote playback getting stuck',
          type: ChangelogEntryType.fix,
        ),
      ],
    );
    final router = _createRouter(version);

    await _pumpRouter(tester, router);
    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.changelogDialogOtherBugFixes), findsOneWidget);
    expect(find.text(l10n.changelogDialogViewAll), findsOneWidget);

    await tester.tap(find.text(l10n.changelogDialogViewAll));
    await tester.pumpAndSettle();

    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/settings/about/changelog',
    );
    expect(find.text(l10n.aboutChangelog), findsOneWidget);
    expect(find.text('Version ${changelogs.first.version}'), findsOneWidget);

    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Version 1.0.10'),
      list,
      const Offset(0, -240),
    );

    expect(find.text('Version 1.0.10'), findsOneWidget);
  });

  testWidgets('dialog changelog rows use the available content width', (
    tester,
  ) async {
    const entryText =
        'A sufficiently long release highlight remains readable in the dialog';
    const version = ChangelogVersion(
      version: '9.9.9',
      entries: [
        ChangelogEntry(entryText, type: ChangelogEntryType.improvement),
      ],
    );
    final router = _createRouter(version);

    await _pumpRouter(tester, router);
    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.text(entryText)).width, greaterThan(300));
  });
}

GoRouter _createRouter(ChangelogVersion version) {
  return GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showChangelogDialog(context, version),
              child: const Text('Open dialog'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/settings/about/changelog',
        builder: (context, state) => const ChangelogScreen(),
      ),
    ],
  );
}

Future<void> _pumpRouter(WidgetTester tester, GoRouter router) {
  return tester.pumpWidget(
    MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}
