import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';

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
    testWidgets('downloaded shows a 16 dp check and is spoken', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpGlyph(
        tester,
        const SongDownloadState(status: SongDownloadStatus.downloaded),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.check_circle));
      expect(icon.size, 16);
      expect(find.bySemanticsLabel('Downloaded'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('downloading shows determinate progress in a 16 dp box', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pumpGlyph(
        tester,
        const SongDownloadState(
          status: SongDownloadStatus.downloading,
          progress: .4,
        ),
      );
      final ring = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(ring.value, .4);
      expect(
        tester.getSize(find.byKey(SongDownloadStatusGlyph.boxKey)),
        const Size(16, 16),
      );
      expect(find.bySemanticsLabel('Downloading…'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('queued shows a faint indeterminate ring', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpGlyph(
        tester,
        const SongDownloadState(status: SongDownloadStatus.queued),
      );
      final ring = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(ring.value, isNull);
      expect(ring.color!.a, closeTo(.5, .01));
      expect(
        tester.getSize(find.byKey(SongDownloadStatusGlyph.boxKey)),
        const Size(16, 16),
      );
      expect(find.bySemanticsLabel('Queued for download'), findsOneWidget);
      semantics.dispose();
    });

    for (final status in [SongDownloadStatus.none, SongDownloadStatus.cached]) {
      testWidgets('$status renders nothing', (tester) async {
        await _pumpGlyph(tester, SongDownloadState(status: status));
        expect(tester.getSize(find.byType(SongDownloadStatusGlyph)), Size.zero);
        expect(find.byType(Icon), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
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
