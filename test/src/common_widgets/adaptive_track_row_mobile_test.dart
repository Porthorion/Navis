import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/marquee_text.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/theme/navis_density_scope.dart';

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
    String title = 'A long song title that must truncate',
    bool desktopRuntime = false,
    bool twoLineTitle = true,
    SongDownloadState? status,
    VoidCallback? onTap,
    bool rtl = false,
  }) async {
    setAdaptiveTestViewport(tester, size);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (status != null)
            songDownloadStateProvider('row').overrideWithValue(status),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: desktopRuntime,
              viewportSize: size,
              safePadding: EdgeInsets.zero,
            ),
            child: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(scale),
              ),
              child: Directionality(
                textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                child: Scaffold(
                  body: Column(
                    children: [
                      AdaptiveTrackHeader(actionExtent: buttons * 48),
                      RepaintBoundary(
                        key: const ValueKey('mobile-row-boundary'),
                        child: AdaptiveTrackRow(
                          key: rowKey,
                          title: title,
                          twoLineTitle: twoLineTitle,
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
                          onTap: onTap,
                          actionExtent: buttons * 48,
                          downloadStatus: status == null
                              ? null
                              : remote
                              ? const SizedBox.shrink()
                              : const SongDownloadStatusGlyph(songId: 'row'),
                          actions: buttons == 0
                              ? null
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (status == null)
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
        ),
      ),
    );
    if (downloadControl == null && status == null) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  for (final width in [320.0, 360.0, 390.0, 448.0]) {
    testWidgets(
      '$width mobile reserves two title lines and keeps 48 px targets',
      (tester) async {
        await render(tester, size: Size(width, 844));
        final row = tester.getRect(find.byKey(rowKey));
        expect(row.height, 72);
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
      },
    );
  }

  testWidgets('numbered reorder rows keep all three targets beside metadata', (
    tester,
  ) async {
    await render(tester, size: const Size(320, 844), leading: 32, buttons: 3);
    expect(tester.getSize(find.byKey(rowKey)).height, 72);
    expect(tester.getRect(find.byKey(downloadKey)).center.dy, 36);
    expect(tester.getRect(find.byKey(moreKey)).center.dy, 36);
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
            expect(tester.getRect(find.byKey(moreKey)).right, width - 4);
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
      expect(tester.getSize(find.byKey(rowKey)).height, 72);
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
      expect(row.height, 72);
      expect(tester.getSize(find.byKey(downloadKey)), const Size(48, 48));
      expect(tester.getSize(find.byKey(moreKey)), const Size(48, 48));
      expect(tester.getRect(find.byKey(moreKey)).center.dy, row.center.dy);
      expect(find.text('3:43'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  const downloaded = SongDownloadState(status: SongDownloadStatus.downloaded);
  const downloading = SongDownloadState(
    status: SongDownloadStatus.downloading,
    progress: .42,
  );
  const queued = SongDownloadState(status: SongDownloadStatus.queued);
  const longTitle =
      'A very long song title that goes on and on and on and on and on '
      'and on and on and on';
  const versionTitle =
      'A very long song title that goes on and on and on (Remastered 2011)';
  final indicatorFinder = find.byIcon(Icons.download_for_offline);

  testWidgets('phone rows show no download button and More stays 48 dp', (
    tester,
  ) async {
    for (final state in [
      SongDownloadState.none,
      queued,
      downloading,
      downloaded,
    ]) {
      await render(tester, status: state);
      final row = tester.getRect(find.byKey(rowKey));
      final more = tester.getRect(find.byKey(moreKey));
      expect(more.size, const Size(48, 48));
      expect(more.center.dy, row.center.dy);
      expect(find.byKey(downloadKey), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  for (final scale in [1.0, 1.3, 2.0]) {
    for (final title in [longTitle, versionTitle]) {
      testWidgets('downloaded and plain rows align at scale $scale: $title', (
        tester,
      ) async {
        Future<List<Rect>> measure(SongDownloadState state) async {
          await render(
            tester,
            size: const Size(360, 844),
            scale: scale,
            title: title,
            status: state,
          );
          return [
            tester.getRect(find.byKey(rowKey)),
            tester.getRect(find.text(title)),
            tester.getRect(find.byKey(moreKey)),
            tester.getRect(find.text('3:43')),
          ];
        }

        final plain = await measure(SongDownloadState.none);
        final marked = await measure(downloaded);
        expect(marked, plain);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the indicator sits on line 2 before the artist, 18 dp wide', (
    tester,
  ) async {
    await render(tester, status: SongDownloadState.none);
    final plain = tester.getRect(find.text('Artist · Album'));
    await render(tester, status: downloaded);
    final text = tester.getRect(find.text('Artist · Album'));
    final icon = tester.getRect(indicatorFinder);
    expect(text.left - plain.left, closeTo(18, 1));
    expect(icon.size, const Size(14, 14));
    expect(icon.right, closeTo(text.left - 4, .5));
    expect(icon.center.dy, inInclusiveRange(text.top, text.bottom));
    expect(icon.left, closeTo(plain.left, .5));
    expect(
      tester.widget<Icon>(indicatorFinder).color,
      NavisTokens.of(tester.element(indicatorFinder)).success,
    );
  });

  testWidgets('RTL puts the indicator at the start, before the artist', (
    tester,
  ) async {
    await render(tester, status: SongDownloadState.none, rtl: true);
    final plain = tester.getRect(find.text('Artist · Album'));
    await render(tester, status: downloaded, rtl: true);
    final text = tester.getRect(find.text('Artist · Album'));
    final icon = tester.getRect(indicatorFinder);
    expect(icon.left, closeTo(text.right + 4, .5));
    expect(icon.right, closeTo(plain.right, .5));
  });

  testWidgets('downloading draws a determinate ring with an arrow', (
    tester,
  ) async {
    await render(tester, status: downloading);
    final ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(ring.value, .42);
    expect(ring.strokeWidth, 1.75);
    expect(
      tester.getSize(find.byKey(SongDownloadStatusGlyph.boxKey)),
      const Size(14, 14),
    );
    final arrow = find.byIcon(Icons.arrow_downward);
    expect(tester.widget<Icon>(arrow).size, 8);
    expect(
      tester.getCenter(arrow),
      tester.getCenter(find.byKey(SongDownloadStatusGlyph.boxKey)),
    );
  });

  testWidgets('queued draws a still dashed ring, not a spinner', (
    tester,
  ) async {
    await render(tester, status: queued);
    await tester.pumpAndSettle();
    expect(find.byKey(SongDownloadStatusGlyph.queuedKey), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester.getSize(find.byKey(SongDownloadStatusGlyph.queuedKey)),
      const Size(14, 14),
    );
  });

  testWidgets('none, cached and failed reserve no space', (tester) async {
    await render(tester, status: SongDownloadState.none);
    final base = tester.getRect(find.text('Artist · Album'));
    await render(
      tester,
      status: const SongDownloadState(status: SongDownloadStatus.cached),
    );
    expect(tester.getRect(find.text('Artist · Album')), base);
    expect(find.byType(Icon), findsNWidgets(2)); // leading + More only
  });

  testWidgets('remote rows never show the indicator', (tester) async {
    await render(tester, status: downloaded, remote: true);
    expect(indicatorFinder, findsNothing);
  });

  testWidgets('a row without metadata keeps its height and shows the mark', (
    tester,
  ) async {
    await render(tester, status: downloaded);
    final height = tester.getSize(find.byKey(rowKey)).height;
    await render(tester, status: downloaded, artist: null, album: null);
    expect(indicatorFinder, findsOneWidget);
    expect(tester.getSize(find.byKey(rowKey)).height, height);
    await render(
      tester,
      status: SongDownloadState.none,
      artist: null,
      album: null,
    );
    expect(tester.getSize(find.byKey(rowKey)).height, height);
  });

  testWidgets('one-line rows (twoLineTitle false) show it before the artist', (
    tester,
  ) async {
    await render(tester, twoLineTitle: false, status: SongDownloadState.none);
    final plain = tester.getRect(find.text('Artist · Album'));
    await render(tester, twoLineTitle: false, status: downloaded);
    final text = tester.getRect(find.text('Artist · Album'));
    expect(text.left - plain.left, closeTo(18, 1));
    expect(indicatorFinder, findsOneWidget);
  });

  testWidgets('the indicator is spoken with its state', (tester) async {
    final semantics = tester.ensureSemantics();
    await render(tester, status: downloaded);
    expect(find.bySemanticsLabel(RegExp('Downloaded')), findsOneWidget);
    await render(tester, status: queued);
    expect(
      find.bySemanticsLabel(RegExp('Queued for download')),
      findsOneWidget,
    );
    await render(tester, status: downloading);
    // The row merges its parts into one node: label and value are spoken
    // with the title.
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Downloading…')),
    );
    expect(node.label, contains('Downloading…'));
    expect(node.value, contains('42%'));
    await render(
      tester,
      status: const SongDownloadState(status: SongDownloadStatus.cached),
    );
    expect(find.bySemanticsLabel(RegExp('Downloaded')), findsNothing);
    semantics.dispose();
  });

  testWidgets('a downloaded phone row shows the mark before the artist', (
    tester,
  ) async {
    await render(tester, status: downloaded);
    await expectLater(
      find.byKey(const ValueKey('mobile-row-boundary')),
      matchesGoldenFile(
        'goldens/adaptive_track_row_mobile_download_indicator_390.png',
      ),
    );
  });

  testWidgets('tapping the indicator plays the row', (tester) async {
    var taps = 0;
    await render(tester, status: downloaded, onTap: () => taps++);
    await tester.tap(indicatorFinder);
    expect(taps, 1);
  });

  testWidgets('medium touch rows keep the 48 dp status box and alignment', (
    tester,
  ) async {
    const size = Size(844, 390);
    await render(tester, size: size, status: SongDownloadState.none);
    final more = tester.getRect(find.byKey(moreKey));
    final time = tester.getRect(find.text('3:43'));
    for (final state in [
      const SongDownloadState(status: SongDownloadStatus.queued),
      downloaded,
    ]) {
      await render(tester, size: size, status: state);
      expect(tester.getRect(find.byKey(moreKey)), more);
      expect(tester.getRect(find.text('3:43')), time);
      final box = tester.getRect(
        state.status == SongDownloadStatus.downloaded
            ? find.byIcon(Icons.download_for_offline)
            : find.byKey(SongDownloadStatusGlyph.queuedKey),
      );
      expect(box.size, const Size(14, 14));
      // 14 dp mark plus its 4 dp end gap, centred in the 48 dp box.
      expect(box.center.dx, closeTo(more.left - 26, 1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('action-free phone rows put the duration on line 2', (
    tester,
  ) async {
    await render(tester, buttons: 0);
    expect(tester.getSize(find.byKey(rowKey)).height, 72);
    expect(
      tester.getRect(find.text('3:43')).top,
      greaterThan(
        tester
            .getRect(find.text('A long song title that must truncate'))
            .center
            .dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape and wide rows keep one line and inline duration', (
    tester,
  ) async {
    for (final size in [
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

  testWidgets("album rows keep each edit's version visible", (tester) async {
    const size = Size(390, 844);
    setAdaptiveTestViewport(tester, size);
    Widget row(String title) => AdaptiveTrackRow(
      title: title,
      artist: 'Artist',
      album: 'Album',
      duration: 223,
      leadingExtent: 32,
      leadingGap: 6,
      actionExtent: 96,
      showAlbumColumn: false,
      leading: const Icon(Icons.album),
      actions: const SizedBox(width: 96, height: 48),
    );
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
          child: Scaffold(
            body: Column(
              children: [
                row('A Very Long Song Name For Testing (Edit)'),
                row('A Very Long Song Name For Testing (Mix)'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rows = find.byType(AdaptiveTrackRow);
    for (final (index, suffix) in [' (Edit)', ' (Mix)'].indexed) {
      final text = find.descendant(
        of: rows.at(index),
        matching: find.textContaining('…$suffix'),
      );
      expect(text, findsOneWidget, reason: suffix);
      expect(tester.widget<Text>(text).data, endsWith('…$suffix'));
      final rect = tester.getRect(text);
      final rowRect = tester.getRect(rows.at(index));
      expect(rowRect.contains(rect.topLeft), isTrue, reason: suffix);
      expect(rowRect.contains(rect.bottomRight), isTrue, reason: suffix);
    }
    expect(tester.takeException(), isNull);
  });

  group('two-line phone rows', () {
    const shortTitle = 'Short';
    const longTitle =
        'A very long song title that goes on and on and on and on and on '
        'and on and on and on and on and on and on and on and on';

    Future<void> pumpRows(
      WidgetTester tester,
      List<String> titles, {
      Size size = const Size(360, 800),
      double scale = 1,
      NavisDensity density = NavisDensity.comfortable,
      bool desktopRuntime = false,
      bool twoLineTitle = true,
      bool selected = false,
      Widget? badge,
      Set<int>? badgeOn,
      bool reserveBadge = false,
      bool remote = false,
      EdgeInsetsGeometry? padding,
    }) async {
      setAdaptiveTestViewport(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: desktopRuntime,
              viewportSize: size,
              safePadding: EdgeInsets.zero,
            ),
            child: NavisDensityScope(
              density: density,
              child: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: Column(
                    children: [
                      for (final (i, title) in titles.indexed)
                        AdaptiveTrackRow(
                          key: ValueKey('row-$i'),
                          title: title,
                          artist: 'Artist',
                          album: 'Album',
                          duration: 223,
                          selected: selected,
                          twoLineTitle: twoLineTitle,
                          badge: badgeOn == null || badgeOn.contains(i)
                              ? badge
                              : null,
                          reserveBadge: reserveBadge,
                          isRemote: remote,
                          padding: padding,
                          leading: const Icon(Icons.album),
                          actionExtent: 48,
                          actions: const SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(Icons.more_vert),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    double height(WidgetTester tester, int i) =>
        tester.getSize(find.byKey(ValueKey('row-$i'))).height;

    for (final density in NavisDensity.values) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final width in [360.0, 412.0]) {
          testWidgets(
            'short and long titles give equal rows: $density, x$scale, $width',
            (tester) async {
              await pumpRows(
                tester,
                [shortTitle, longTitle, 'Mid (Remastered 2011)'],
                size: Size(width, 800),
                scale: scale,
                density: density,
              );
              expect(height(tester, 1), height(tester, 0));
              expect(height(tester, 2), height(tester, 0));
              expect(tester.takeException(), isNull);
              if (scale == 1 && density == NavisDensity.comfortable) {
                expect(height(tester, 0), closeTo(72, .5));
              }
              if (scale > 1) {
                final base = scale == 1.3 ? 72 : 88;
                expect(height(tester, 0), greaterThan(base));
              }
            },
          );
        }
      }
    }

    for (final density in NavisDensity.values) {
      testWidgets('stacked controls keep short and long rows equal: $density', (
        tester,
      ) async {
        await pumpRows(
          tester,
          [shortTitle, longTitle],
          size: const Size(320, 800),
          scale: 2,
          density: density,
        );
        expect(height(tester, 1), height(tester, 0));
        expect(tester.takeException(), isNull);
      });
    }

    for (final (width, scale) in [(360.0, 2.0), (412.0, 2.0), (320.0, 1.3)]) {
      for (final density in NavisDensity.values) {
        testWidgets(
          'remote rows keep short and long equal: $density, x$scale, $width',
          (tester) async {
            await pumpRows(
              tester,
              [shortTitle, longTitle],
              size: Size(width, 800),
              scale: scale,
              density: density,
              remote: true,
            );
            expect(height(tester, 1), height(tester, 0));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets('reserveBadge keeps rows with and without a badge equal', (
      tester,
    ) async {
      await pumpRows(
        tester,
        [shortTitle, shortTitle, longTitle],
        badgeOn: {0},
        reserveBadge: true,
        badge: Builder(
          builder: (context) => Text(
            '12 listeners',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
      expect(height(tester, 1), height(tester, 0));
      expect(height(tester, 2), height(tester, 0));
    });

    testWidgets('a tablet playing row still uses the marquee', (tester) async {
      await pumpRows(
        tester,
        [longTitle],
        size: const Size(800, 800),
        selected: true,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<MarqueeText>(find.byType(MarqueeText).first).maxLines,
        1,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_MarqueeScroller',
        ),
        findsOneWidget,
      );
    });

    testWidgets('twoLineTitle false keeps one line when playing', (
      tester,
    ) async {
      await pumpRows(
        tester,
        [longTitle],
        size: const Size(412, 800),
        selected: true,
        twoLineTitle: false,
      );
      expect(tester.widget<MarqueeText>(find.byType(MarqueeText)).maxLines, 1);
    });

    testWidgets('a short title is centred in the reserved height', (
      tester,
    ) async {
      await pumpRows(tester, [shortTitle]);
      final row = tester.getRect(find.byKey(const ValueKey('row-0')));
      final top = tester.getRect(find.text(shortTitle)).top;
      final bottom = tester.getRect(find.text('Artist · Album')).bottom;
      expect(top - row.top, closeTo(row.bottom - bottom, 1));
    });

    testWidgets('a badge adds its line to the reserve', (tester) async {
      await pumpRows(tester, [shortTitle, longTitle]);
      final plain = height(tester, 0);
      await pumpRows(
        tester,
        [shortTitle, longTitle],
        badge: Builder(
          builder: (context) => Text(
            'FLAC · 12 MB',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
      expect(height(tester, 0), greaterThan(plain));
      expect(height(tester, 1), height(tester, 0));
    });

    testWidgets('a credit title ends line 2 in one ellipsis', (tester) async {
      const title =
          'Dearly Beloved (From "Kingdom Hearts" Original Soundtrack)';
      await pumpRows(tester, [title], size: const Size(250, 800));
      final text = tester.widget<Text>(find.text(title));
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('a long base keeps (Edit) whole on line 2', (tester) async {
      await pumpRows(tester, [
        'A very long song title that cannot fit in two lines at all (Edit)',
      ], size: const Size(412, 800));
      final shown = tester.widget<MarqueeText>(find.byType(MarqueeText)).text;
      expect(shown, endsWith('(Edit)'));
      final rendered = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(MarqueeText),
              matching: find.byType(Text),
            ),
          )
          .single
          .data!;
      expect(rendered, endsWith('… (Edit)'));
      expect('…'.allMatches(rendered), hasLength(1));
    });

    testWidgets('the duration is on line 2 at 412 too and the title is wider', (
      tester,
    ) async {
      await pumpRows(tester, [longTitle], size: const Size(360, 800));
      final narrow = tester.getRect(find.byType(MarqueeText)).width;
      await pumpRows(tester, [longTitle], size: const Size(412, 800));
      final title = tester.getRect(find.byType(MarqueeText));
      expect(title.width, greaterThan(narrow));
      final duration = tester.getRect(find.text('3:43'));
      expect(duration.top, greaterThanOrEqualTo(title.bottom - 1));
    });

    testWidgets('the end inset is 4 next to the more glyph', (tester) async {
      await pumpRows(tester, [shortTitle]);
      final row = tester.getRect(find.byKey(const ValueKey('row-0')));
      final glyph = tester.getRect(find.byIcon(Icons.more_vert));
      // 4 inset + half the 48 box: the glyph's centre is 28 from the edge.
      expect(row.right - glyph.center.dx, 28);
    });

    testWidgets('explicit padding keeps its end inset', (tester) async {
      await pumpRows(tester, [
        shortTitle,
      ], padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4));
      final row = tester.getRect(find.byKey(const ValueKey('row-0')));
      final glyph = tester.getRect(find.byIcon(Icons.more_vert));
      expect(row.right - glyph.center.dx, 32);
    });

    testWidgets('a playing phone row has the marker colour and no marquee', (
      tester,
    ) async {
      await pumpRows(tester, [longTitle], selected: true);
      await tester.pump(const Duration(seconds: 3));
      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_MarqueeScroller',
        ),
        findsNothing,
      );
      expect(tester.widget<MarqueeText>(find.byType(MarqueeText)).maxLines, 2);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('desktop compact rows are unchanged', (tester) async {
      await pumpRows(
        tester,
        [shortTitle, longTitle],
        size: const Size(440, 800),
        desktopRuntime: true,
      );
      expect(height(tester, 0), 64);
      expect(height(tester, 1), 64);
      expect(
        tester.widget<MarqueeText>(find.byType(MarqueeText).first).maxLines,
        1,
      );
      final row = tester.getRect(find.byKey(const ValueKey('row-0')));
      final glyph = tester.getRect(find.byIcon(Icons.more_vert).first);
      expect(row.right - glyph.center.dx, 36);
    });

    testWidgets('twoLineTitle false keeps one line and 64 dp', (tester) async {
      await pumpRows(
        tester,
        [shortTitle, longTitle],
        size: const Size(412, 800),
        twoLineTitle: false,
      );
      expect(height(tester, 0), 64);
      expect(height(tester, 1), 64);
      expect(
        tester.widget<MarqueeText>(find.byType(MarqueeText).first).maxLines,
        1,
      );
    });

    testWidgets('song skeleton rows match the reserved row height', (
      tester,
    ) async {
      for (final scale in [1.0, 1.3]) {
        await pumpRows(tester, [shortTitle], scale: scale);
        final row = height(tester, 0);
        setAdaptiveTestViewport(tester, const Size(360, 800));
        await tester.pumpWidget(
          MaterialApp(
            theme: testTheme(),
            home: AdaptiveContextScope(
              adaptiveContext: resolveAdaptiveContext(
                desktopRuntime: false,
                viewportSize: const Size(360, 800),
                safePadding: EdgeInsets.zero,
              ),
              child: MediaQuery(
                data: MediaQueryData(
                  size: const Size(360, 800),
                  textScaler: TextScaler.linear(scale),
                ),
                child: const Scaffold(
                  body: ShimmerListPage(count: 1, songRows: true),
                ),
              ),
            ),
          ),
        );
        expect(tester.getSize(find.byType(ShimmerListTile)).height, row);
      }
    });
  });
}
