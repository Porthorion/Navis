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
                          badge: badge,
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
