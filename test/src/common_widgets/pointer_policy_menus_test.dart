import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/song_sheet_header.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_theme.dart';

const _song = SongsTableData(
  id: 's1',
  title: 'Song',
  isProvisional: false,
  isExternal: false,
);

/// Mirrors the real callers: secondary click passes the pointer position,
/// long-press passes no anchor.
Future<void> _pumpRow(WidgetTester tester, Size size, NavisDatabase db) async {
  setAdaptiveTestViewport(tester, size);
  final policy = resolveAdaptiveInputPolicy(
    adaptiveContext: resolveAdaptiveContext(
      desktopRuntime: false,
      viewportSize: size,
      safePadding: EdgeInsets.zero,
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(db),
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdaptiveInputPolicyScope(
          policy: policy,
          child: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: GestureDetector(
                  onLongPress: () => showSongContextMenu(context, ref, _song),
                  onSecondaryTapDown: (details) => showSongContextMenu(
                    context,
                    ref,
                    _song,
                    anchor: details.globalPosition,
                  ),
                  child: const SizedBox(
                    key: ValueKey<String>('row'),
                    width: 300,
                    height: 56,
                    child: Text('Song row'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late NavisDatabase db;

  setUp(() {
    db = createTestDatabase();
    addTearDown(db.close);
    debugDesktopRuntimeOverride = false;
    addTearDown(() => debugDesktopRuntimeOverride = null);
  });

  // Foundation vars must be unset before the test body returns.
  void iosTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  final row = find.byKey(const ValueKey<String>('row'));

  iosTest('tablet secondary click opens the anchored popup menu', (
    tester,
  ) async {
    await _pumpRow(tester, const Size(1032, 1376), db);
    await tester.tap(row, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Play Now'), findsOneWidget);
    expect(find.byType(SongSheetHeader), findsNothing);
  });

  iosTest('tablet long-press still opens the bottom sheet', (tester) async {
    await _pumpRow(tester, const Size(1032, 1376), db);
    await tester.longPress(row);
    await tester.pumpAndSettle();
    expect(find.byType(SongSheetHeader), findsOneWidget);
  });

  iosTest('phone secondary click keeps the bottom sheet', (tester) async {
    await _pumpRow(tester, const Size(390, 844), db);
    await tester.tap(row, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byType(SongSheetHeader), findsOneWidget);
  });
}
