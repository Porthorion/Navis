import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';

import '../../../../helpers/test_database.dart';

void main() {
  testWidgets('desktop uses a bounded download-quality dialog', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1366, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
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

  testWidgets('the picker offers every bitrate in the chosen format', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1366, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    DownloadQualityChoice? picked;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async => picked = await showDownloadQualitySheet(
              context,
              format: 'opus',
              initialChoice: const DownloadQualityChoice(
                quality: '192',
                format: 'opus',
              ),
            ),
            child: const Text('Choose quality'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose quality'));
    await tester.pumpAndSettle();

    for (final kbps in kDownloadBitRateOptions) {
      expect(find.text('$kbps kbps OPUS'), findsOneWidget);
    }
    final checked = find.ancestor(
      of: find.byIcon(Icons.check),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: checked, matching: find.text('192 kbps OPUS')),
      findsOneWidget,
    );

    await tester.tap(find.text('256 kbps OPUS'));
    await tester.pumpAndSettle();
    expect(picked?.quality, '256');
    expect(picked?.format, 'opus');
    expect(picked?.automatic, isFalse);
  });

  group('requestDownloadQuality', () {
    late NavisDatabase database;

    setUp(() => database = createTestDatabase());
    tearDown(() => database.close());

    Future<List<DownloadQualityChoice?>> pumpRequester(
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1366, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final results = <DownloadQualityChoice?>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(database),
          child: MaterialApp(
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) => FilledButton(
                onPressed: () async =>
                    results.add(await requestDownloadQuality(context, ref)),
                child: const Text('Download'),
              ),
            ),
          ),
        ),
      );
      return results;
    }

    Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      // Database reads resolve outside the fake clock.
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('the first pick asks once whether to always use it', (
      tester,
    ) async {
      final results = await pumpRequester(tester);

      await tapAndSettle(tester, find.text('Download'));
      expect(find.text('Download Quality'), findsOneWidget);
      await tapAndSettle(tester, find.text('320 kbps MP3'));

      expect(
        find.byKey(const ValueKey<String>('downloadQualityAlwaysPrompt')),
        findsOneWidget,
      );
      expect(find.text('Always download in 320 kbps MP3?'), findsOneWidget);
      await tapAndSettle(
        tester,
        find.byKey(const ValueKey<String>('downloadQualityAlwaysUse')),
      );

      expect(results.single?.quality, '320');
      final preference = await tester.runAsync(
        () => database.appSettingsDao.getDownloadQualityPreference(),
      );
      expect(preference!.mode, DownloadQualityMode.transcode);
      expect(preference.bitRate, 320);
      expect(preference.format, 'mp3');
      expect(preference.prompted, isTrue);

      // Later downloads use the preference without any picker.
      await tapAndSettle(tester, find.text('Download'));
      expect(find.text('Download Quality'), findsNothing);
      expect(results.last?.quality, '320');
      expect(results.last?.automatic, isTrue);
    });

    testWidgets('"Ask every time" keeps asking and never prompts again', (
      tester,
    ) async {
      final results = await pumpRequester(tester);

      await tapAndSettle(tester, find.text('Download'));
      await tapAndSettle(tester, find.text('Original quality'));
      await tapAndSettle(
        tester,
        find.byKey(const ValueKey<String>('downloadQualityAlwaysAsk')),
      );
      expect(results.single?.isOriginal, isTrue);
      final preference = await tester.runAsync(
        () => database.appSettingsDao.getDownloadQualityPreference(),
      );
      expect(preference!.mode, DownloadQualityMode.ask);
      expect(preference.prompted, isTrue);

      await tapAndSettle(tester, find.text('Download'));
      expect(find.text('Download Quality'), findsOneWidget);
      await tapAndSettle(tester, find.text('128 kbps MP3'));
      expect(
        find.byKey(const ValueKey<String>('downloadQualityAlwaysPrompt')),
        findsNothing,
      );
      expect(results.last?.quality, '128');
      expect(results.last?.automatic, isFalse);
    });

    testWidgets('cancelling the picker downloads nothing and does not prompt', (
      tester,
    ) async {
      final results = await pumpRequester(tester);
      await tapAndSettle(tester, find.text('Download'));
      expect(find.text('Download Quality'), findsOneWidget);
      await tester.tapAt(const Offset(8, 8));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
      }
      expect(results.single, isNull);
      final preference = await tester.runAsync(
        () => database.appSettingsDao.getDownloadQualityPreference(),
      );
      expect(preference!.prompted, isFalse);
    });
  });

  testWidgets('the queued notice names the quality only when automatic', (
    tester,
  ) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(
      downloadQueuedNotice(
        l10n,
        'Download queued.',
        const DownloadQualityChoice(quality: '192', format: 'opus'),
      ),
      'Download queued.',
    );
    expect(
      downloadQueuedNotice(
        l10n,
        'Download queued.',
        const DownloadQualityChoice(automatic: true),
      ),
      'Download queued · Original quality',
    );
  });
}
