import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_screen.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_theme.dart';

class _Queue extends QueueController {
  @override
  List<String> build() => const [];
}

void main() {
  for (final width in [390.0, 800.0, 1200.0]) {
    testWidgets('unavailable queue rows stay removable at width $width', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, Size(width, 700));
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final container = ProviderContainer(
        overrides: [
          subsonicApiProvider.overrideWithValue(null),
          queueProvider.overrideWith(_Queue.new),
          playerStateProvider.overrideWithValue(const PlaybackSnapshot.idle()),
        ],
      );
      addTearDown(container.dispose);
      container.read(retainedArtistQueueProvider.notifier).retain(const [
        SongsTableData(
          id: 'ext-unavailable',
          title: 'Remote track with a long descriptive release title',
          isExternal: true,
          isProvisional: true,
        ),
      ], append: false);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: width < 800
                ? Scaffold(
                    body: QueueSheet(
                      scrollController: scrollController,
                      onClose: () {},
                      embeddedMode: true,
                    ),
                  )
                : const QueueScreen(),
          ),
        ),
      );
      await tester.pump();
      final row = find.byKey(const ValueKey('unavailable-0-ext-unavailable'));
      expect(row, findsOneWidget);
      expect(tester.widget<ListTile>(row).onTap, isNull);
      expect(find.text('Unavailable · skipped automatically'), findsOneWidget);
      expect(find.text('Your queue is empty'), findsNothing);
      final title = tester.widget<Text>(
        find.text('Remote track with a long descriptive release title'),
      );
      expect(title.style!.color, Theme.of(tester.element(row)).disabledColor);
      await tester.tap(
        find.descendant(of: row, matching: find.byType(IconButton)),
      );
      await tester.pump();
      expect(container.read(retainedArtistQueueProvider), isEmpty);
      expect(container.read(queueProvider), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
