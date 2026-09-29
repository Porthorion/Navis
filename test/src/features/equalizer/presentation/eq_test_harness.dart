import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

/// The single Advanced band used by the precision tests.
final eqPrecisionFixture = EqConfiguration(
  mode: EqMode.advanced,
  filters: const [
    EqFilter(frequencyHz: 1234.56789, gainDb: 3.12735, q: 1.4142135623730951),
  ],
);

/// Mounts the production Equalizer page over an isolated test database.
Future<ProviderContainer> mount(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  bool desktop = false,
  double scale = 1,
  bool keyboard = false,
  bool dark = false,
  EqConfiguration? configuration,
}) async {
  setAdaptiveTestViewport(tester, size);
  final db = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(
      db,
      overrides: [
        audioHandlerProvider.overrideWithValue(null),
        eqCapabilitiesProvider.overrideWithValue(EqCapabilities.available),
      ],
    ),
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });
  await container.read(equalizerProvider.future);
  await container
      .read(equalizerProvider.notifier)
      .setConfiguration(configuration ?? eqPrecisionFixture);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: dark ? ThemeData.dark() : testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard ? 300 : 0),
          ),
          child: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: desktop,
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
  return container;
}
