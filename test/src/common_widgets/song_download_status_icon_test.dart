import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';

import 'package:navis/src/theme/navis_tokens.dart';

import '../../helpers/test_theme.dart';

Future<void> _pump(WidgetTester tester, {VoidCallback? onDownload}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        songDownloadStateProvider('s').overrideWithValue(
          const SongDownloadState(status: SongDownloadStatus.cached),
        ),
      ],
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SongDownloadStatusIcon(songId: 's', onDownload: onDownload),
          ),
        ),
      ),
    ),
  );
}

void main() {
  _glyphTests();
  testWidgets('tapping the cached icon calls onDownload', (tester) async {
    var taps = 0;
    await _pump(tester, onDownload: () => taps++);
    await tester.tap(find.byIcon(Icons.schedule));
    expect(taps, 1);
  });

  testWidgets('cached icon is not interactive without onDownload', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
  });
}

Future<void> _pumpGlyph(WidgetTester tester, SongDownloadState state) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [songDownloadStateProvider('s').overrideWithValue(state)],
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Center(child: SongDownloadStatusGlyph(songId: 's')),
        ),
      ),
    ),
  );
}

void _glyphTests() {
  group('SongDownloadStatusGlyph', () {
    testWidgets('downloaded is a 14 dp success circle and is spoken', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pumpGlyph(
        tester,
        const SongDownloadState(status: SongDownloadStatus.downloaded),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.download_for_offline));
      expect(icon.size, 14);
      expect(
        icon.color,
        NavisTokens.of(tester.element(find.byType(Icon))).success,
      );
      expect(find.bySemanticsLabel('Downloaded'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('downloading is a 14 dp ring with an arrow and its percent', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pumpGlyph(
        tester,
        const SongDownloadState(
          status: SongDownloadStatus.downloading,
          progress: .42,
        ),
      );
      final ring = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(ring.value, .42);
      expect(ring.strokeWidth, 1.75);
      expect(tester.widget<Icon>(find.byIcon(Icons.arrow_downward)).size, 8);
      expect(
        tester.getSize(find.byKey(SongDownloadStatusGlyph.boxKey)),
        const Size(14, 14),
      );
      final node = tester.getSemantics(find.bySemanticsLabel('Downloading…'));
      expect(node.value, '42%');
      semantics.dispose();
    });

    testWidgets('queued is a still dashed ring', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpGlyph(
        tester,
        const SongDownloadState(status: SongDownloadStatus.queued),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.getSize(find.byKey(SongDownloadStatusGlyph.queuedKey)),
        const Size(14, 14),
      );
      expect(find.bySemanticsLabel('Queued for download'), findsOneWidget);
      semantics.dispose();
    });

    for (final status in [SongDownloadStatus.none, SongDownloadStatus.cached]) {
      testWidgets('$status renders nothing and has no semantics', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await _pumpGlyph(tester, SongDownloadState(status: status));
        expect(tester.getSize(find.byType(SongDownloadStatusGlyph)), Size.zero);
        expect(find.byType(Icon), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.bySemanticsLabel('Downloaded'), findsNothing);
        semantics.dispose();
      });
    }

    testWidgets('has no tap target', (tester) async {
      await _pumpGlyph(
        tester,
        const SongDownloadState(status: SongDownloadStatus.downloaded),
      );
      final glyph = find.byType(SongDownloadStatusGlyph);
      for (final type in [IconButton, InkWell, GestureDetector]) {
        expect(
          find.descendant(of: glyph, matching: find.byType(type)),
          findsNothing,
        );
      }
    });
  });
}
