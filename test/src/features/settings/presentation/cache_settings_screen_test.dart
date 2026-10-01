import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/settings/presentation/cache_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows an active write before completed cache totals update', (
    tester,
  ) async {
    final database = createTestDatabase();
    final statsController = StreamController<CacheStats>.broadcast();
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          rollingCacheStatsProvider.overrideWith(
            (ref) => statsController.stream,
          ),
          rollingCacheActivityProvider.overrideWith(
            _ActiveRollingCacheActivityController.new,
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await statsController.close();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const CacheSettingsScreen(),
        ),
      ),
    );
    statsController.add(const CacheStats(trackCount: 0, totalBytes: 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('No cached tracks'), findsOneWidget);
    expect(find.text('Caching current track… 25%'), findsOneWidget);

    statsController.add(const CacheStats(trackCount: 1, totalBytes: 4096));
    container
        .read(rollingCacheActivityProvider.notifier)
        .update(const RollingCacheActivity.idle());
    await tester.pump();

    expect(find.text('1 cached track'), findsOneWidget);
    expect(find.textContaining('Caching current track'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pump();
    expect(find.text('Reset Caches & Rebuild Library'), findsOneWidget);
    expect(
      find.text(
        'Clear local streaming and artwork caches plus library metadata, then rebuild from the server. Downloaded music is kept.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('uses a focused workspace and Settings return path on desktop', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1280, 800));
    final database = createTestDatabase();
    final statsController = StreamController<CacheStats>.broadcast();
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          rollingCacheStatsProvider.overrideWith(
            (ref) => statsController.stream,
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await statsController.close();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: true,
              viewportSize: const Size(1280, 800),
              safePadding: EdgeInsets.zero,
            ),
            child: const CacheSettingsScreen(),
          ),
        ),
      ),
    );
    statsController.add(const CacheStats(trackCount: 0, totalBytes: 0));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(tester.getSize(find.byType(ListView)).width, 1040);
    await expectLater(
      find.byType(CacheSettingsScreen),
      matchesGoldenFile('goldens/cache_settings_desktop_workspace.png'),
    );
  });
}

class _ActiveRollingCacheActivityController
    extends RollingCacheActivityController {
  @override
  RollingCacheActivity build() => const RollingCacheActivity(
    status: RollingCacheActivityStatus.caching,
    songId: 'song-1',
    progress: 0.25,
  );
}
