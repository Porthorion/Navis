import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/test_theme.dart';

void main() {
  const rowKey = ValueKey('mobile-row');
  const downloadKey = ValueKey('download');
  const moreKey = ValueKey('more');
  const leadingKey = ValueKey('leading');
  Future<void> render(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double scale = 1,
    double leading = 48,
    int buttons = 2,
    int? duration = 223,
    String? artist = 'Artist',
    String? album = 'Album',
    bool remote = false,
    Widget? badge,
    bool selected = false,
    Widget? downloadControl,
  }) async {
    setAdaptiveTestViewport(tester, size);
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdaptiveContextScope(
          adaptiveContext: resolveAdaptiveContext(
            desktopRuntime: false,
            viewportSize: size,
            safePadding: EdgeInsets.zero,
          ),
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: Column(
                children: [
                  AdaptiveTrackHeader(actionExtent: buttons * 48),
                  RepaintBoundary(
                    key: const ValueKey('mobile-row-boundary'),
                    child: AdaptiveTrackRow(
                      key: rowKey,
                      title: 'A long song title that must truncate',
                      artist: artist,
                      album: album,
                      duration: duration,
                      leadingExtent: leading,
                      leading: const SizedBox(
                        key: leadingKey,
                        height: 48,
                        child: Icon(Icons.album),
                      ),
                      isRemote: remote,
                      badge: badge,
                      selected: selected,
                      actionExtent: buttons * 48,
                      actions: buttons == 0
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 48,
                                  height: 48,
                                  child:
                                      downloadControl ??
                                      IconButton(
                                        key: downloadKey,
                                        tooltip: 'Download',
                                        onPressed: () {},
                                        icon: const Icon(Icons.download),
                                      ),
                                ),
                                if (buttons >= 2)
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: IconButton(
                                      key: moreKey,
                                      tooltip: 'More',
                                      onPressed: () {},
                                      icon: const Icon(Icons.more_vert),
                                    ),
                                  ),
                                if (buttons == 3)
                                  const SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Icon(Icons.drag_handle),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (downloadControl == null) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  for (final width in [320.0, 360.0, 390.0, 448.0]) {
    testWidgets('$width mobile keeps default rows and targets at 64/48 px', (
      tester,
    ) async {
      await render(tester, size: Size(width, 844));
      final row = tester.getRect(find.byKey(rowKey));
      expect(row.height, 64);
      final title = tester.getRect(
        find.text('A long song title that must truncate'),
      );
      final duration = tester.getRect(find.text('3:43'));
      expect(duration.top, greaterThan(title.top));
      expect(duration.left, greaterThanOrEqualTo(title.left));
      for (final key in [downloadKey, moreKey]) {
        final target = tester.getRect(find.byKey(key));
        expect(target.size, const Size(48, 48));
        expect(target.center.dy, row.center.dy);
        expect(target.left, greaterThan(duration.right));
      }
      expect(find.text('3:43'), findsOneWidget);
      expect(find.text('#'), findsNothing);
      expect(tester.takeException(), isNull);
      if (width == 390) {
        await expectLater(
          find.byKey(const ValueKey('mobile-row-boundary')),
          matchesGoldenFile('goldens/adaptive_track_row_mobile_390.png'),
        );
      }
    });
  }

  testWidgets('numbered reorder rows keep all three targets beside metadata', (
    tester,
  ) async {
    await render(tester, size: const Size(320, 844), leading: 32, buttons: 3);
    expect(tester.getSize(find.byKey(rowKey)).height, 64);
    expect(tester.getRect(find.byKey(downloadKey)).center.dy, 32);
    expect(tester.getRect(find.byKey(moreKey)).center.dy, 32);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('metadata and duration stay with text at scale $scale', (
      tester,
    ) async {
      for (final width in [320.0, 360.0, 390.0, 448.0]) {
        for (final duration in [null, 3661]) {
          await render(
            tester,
            size: Size(width, 844),
            scale: scale,
            duration: duration,
            remote: true,
            selected: true,
            artist: 'A very long artist name',
            album: 'A very long album name',
            badge: const Text('Matching'),
          );
          final value = duration == null ? '--:--' : '1:01:01';
          expect(find.text(value), findsOneWidget);
          final title = tester.getRect(
            find.text('A long song title that must truncate'),
          );
          final time = tester.getRect(find.text(value));
          expect(time.left, greaterThanOrEqualTo(title.left));
          expect(
            time.right,
            lessThanOrEqualTo(tester.getRect(find.byKey(rowKey)).right),
          );
          expect(time.width, greaterThan(0));
          expect(find.byType(RemoteSourceIndicator), findsOneWidget);
          final available = width - 24 - 48 - 12 - 104;
          final controls = tester.getRect(find.byKey(downloadKey));
          if (available >= 96 * scale) {
            expect(controls.left, greaterThan(time.right));
          } else {
            expect(controls.top, greaterThan(time.bottom));
            expect(tester.getRect(find.byKey(moreKey)).right, width - 12);
          }
          expect(tester.takeException(), isNull);
        }
      }
    });
  }

  testWidgets(
    'missing metadata retains readable duration and compact targets',
    (tester) async {
      await render(tester, artist: null, album: null, duration: null);
      expect(find.text('--:--'), findsOneWidget);
      expect(tester.getSize(find.byKey(rowKey)).height, 64);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('download states retain compact geometry and the More target', (
    tester,
  ) async {
    for (final status in SongDownloadStatus.values) {
      await render(
        tester,
        downloadControl: ProviderScope(
          overrides: [
            songDownloadStateProvider('row-download').overrideWithValue(
              SongDownloadState(status: status, progress: .5),
            ),
          ],
          child: SongDownloadStatusIcon(
            key: downloadKey,
            songId: 'row-download',
            onDownload: () {},
          ),
        ),
      );
      final row = tester.getRect(find.byKey(rowKey));
      expect(row.height, 64);
      expect(tester.getSize(find.byKey(downloadKey)), const Size(48, 48));
      expect(tester.getSize(find.byKey(moreKey)), const Size(48, 48));
      expect(tester.getRect(find.byKey(moreKey)).center.dy, row.center.dy);
      expect(find.text('3:43'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('working action-free and landscape rows retain inline duration', (
    tester,
  ) async {
    for (final size in [
      const Size(390, 844),
      const Size(844, 390),
      const Size(800, 1000),
      const Size(1200, 900),
    ]) {
      await render(tester, size: size, buttons: 0);
      expect(tester.getSize(find.byKey(rowKey)).height, 64);
      expect(
        tester.getRect(find.text('3:43')).center.dy,
        tester.getRect(find.byKey(leadingKey)).center.dy,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
