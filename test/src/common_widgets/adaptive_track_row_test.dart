import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/routing/content_layout.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/test_theme.dart';

void main() {
  Future<void> render(
    WidgetTester tester,
    double width, {
    TextScaler scaler = TextScaler.noScaling,
  }) async {
    setAdaptiveTestViewport(tester, Size(width, 600));
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: scaler),
            child: const Scaffold(
              body: Column(
                children: [
                  AdaptiveTrackHeader(actionExtent: 48),
                  AdaptiveTrackRow(
                    title: 'A long song title',
                    artist: 'An artist',
                    album: 'An album',
                    duration: 223,
                    actionExtent: 48,
                    leading: Icon(Icons.music_note),
                    actions: IconButton(
                      onPressed: null,
                      icon: Icon(Icons.more_horiz),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('title badges share the title line in dense rows', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1000, 600));
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Column(
            children: [
              AdaptiveTrackRow(
                key: ValueKey('dense'),
                title: 'Unmatched title',
                artist: 'An artist',
                album: 'An album',
                minHeight: 48,
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                titleBadge: Text('Not on server'),
                leading: Text('6'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('dense'));
    expect(tester.getSize(row).height, 48);
    final title = tester.getRect(find.text('Unmatched title'));
    final badge = tester.getRect(find.text('Not on server'));
    expect(badge.center.dy, closeTo(title.center.dy, 2));
    expect(badge.left, greaterThan(title.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide remote rows keep the badge on the title line', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1000, 600));
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Column(
            children: [
              AdaptiveTrackRow(
                key: ValueKey('local'),
                title: 'Local title',
                artist: 'An artist',
                album: 'An album',
                duration: 223,
                leading: Icon(Icons.music_note),
              ),
              AdaptiveTrackRow(
                key: ValueKey('remote'),
                title: 'Remote title',
                artist: 'An artist',
                album: 'An album',
                duration: 223,
                isRemote: true,
                leading: Icon(Icons.music_note),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final local = find.byKey(const ValueKey('local'));
    final remote = find.byKey(const ValueKey('remote'));
    expect(tester.getSize(remote).height, tester.getSize(local).height);
    final title = tester.getRect(find.text('Remote title'));
    expect(title.left, tester.getRect(find.text('Local title')).left);
    final badge = tester.getRect(
      find.descendant(of: remote, matching: find.byType(RemoteSourceIndicator)),
    );
    expect(badge.center.dy, closeTo(title.center.dy, 2));
    expect(badge.left, greaterThan(title.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow row actions keep every column under its heading', (
    tester,
  ) async {
    for (final width in <double>[1000, 800]) {
      setAdaptiveTestViewport(tester, Size(width, 600));
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                const AdaptiveTrackHeader(),
                AdaptiveTrackRow(
                  title: 'A long song title',
                  artist: 'An artist',
                  album: 'An album',
                  duration: 223,
                  leading: const Icon(Icons.music_note),
                  // Narrower than the width the header reserves: three
                  // compact icons when wide, the More button alone when not.
                  actions: SizedBox(
                    width: width == 1000 ? 120 : 40,
                    height: 40,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('An artist')).left,
        tester.getRect(find.text('Artist')).left,
        reason: 'artist at $width',
      );
      if (width == 1000) {
        expect(
          tester.getRect(find.text('An album')).left,
          tester.getRect(find.text('Album')).left,
        );
      }
      expect(
        tester.getRect(find.text('3:43')).right,
        closeTo(tester.getRect(find.text('Time')).right, 0.5),
        reason: 'time at $width',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('album track lists omit the repeated album at every width', (
    tester,
  ) async {
    for (final width in <double>[1000, 800, 390]) {
      setAdaptiveTestViewport(tester, Size(width, 600));
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Column(
              children: [
                AdaptiveTrackHeader(actionExtent: 48, showAlbumColumn: false),
                AdaptiveTrackRow(
                  title: 'A long song title',
                  artist: 'An artist',
                  album: 'An album',
                  duration: 223,
                  actionExtent: 48,
                  showAlbumColumn: false,
                  leading: Icon(Icons.music_note),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Album'), findsNothing, reason: 'width $width');
      expect(find.textContaining('An album'), findsNothing);
      expect(find.textContaining('An artist'), findsOneWidget);
      if (width == 1000) {
        expect(
          tester.getRect(find.text('An artist')).left,
          tester.getRect(find.text('Artist')).left,
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('local pane selects metadata columns and matching headings', (
    tester,
  ) async {
    await render(tester, 1000);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('Album'), findsOneWidget);
    expect(find.text('An artist'), findsOneWidget);
    expect(find.text('An album'), findsOneWidget);
    expect(find.text('3:43'), findsOneWidget);
    expect(find.text('#'), findsNothing);
    final headerArtist = tester.getRect(find.text('Artist'));
    final rowArtist = tester.getRect(find.text('An artist'));
    expect(rowArtist.left, headerArtist.left);
    await render(tester, 800);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('Album'), findsNothing);
    expect(find.text('An album'), findsOneWidget);
    await render(tester, 390);
    expect(find.text('Artist'), findsNothing);
    expect(find.text('An artist · An album'), findsOneWidget);
    expect(find.text('3:43'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final geometry in [
    (leading: 32.0, number: 32.0),
    (leading: 82.0, number: 30.0),
  ]) {
    testWidgets(
      'number heading aligns with ${geometry.number}px numeric area and preserves metadata columns',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          for (final viewport in [
            (width: 800.0, scale: 1.0),
            (width: 1000.0, scale: 1.0),
            (width: 2000.0, scale: 2.0),
            (width: 390.0, scale: 1.0),
          ]) {
            setAdaptiveTestViewport(tester, Size(viewport.width, 600));
            await tester.pumpWidget(
              MaterialApp(
                theme: testTheme(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(viewport.scale)),
                    child: Scaffold(
                      body: Column(
                        children: [
                          AdaptiveTrackHeader(
                            numberColumnExtent: geometry.number,
                            leadingExtent: geometry.leading,
                            leadingGap: 6,
                            actionExtent: 48,
                          ),
                          AdaptiveTrackRow(
                            title: 'Track title',
                            artist: 'Track artist',
                            album: 'Track album',
                            duration: 223,
                            leadingExtent: geometry.leading,
                            leadingGap: 6,
                            actionExtent: 48,
                            leading: Row(
                              children: [
                                SizedBox(
                                  width: geometry.number,
                                  child: const Center(child: Text('7')),
                                ),
                                if (geometry.leading > geometry.number)
                                  Expanded(child: Icon(Icons.album)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            if (viewport.width == 390) {
              expect(find.text('#'), findsNothing);
              expect(find.bySemanticsLabel('Track number'), findsNothing);
            } else {
              expect(find.text('#'), findsOneWidget);
              expect(find.bySemanticsLabel('Track number'), findsOneWidget);
              expect(
                tester.getSemantics(find.bySemanticsLabel('Track number')),
                matchesSemantics(label: 'Track number', isHeader: true),
              );
              expect(
                tester.getRect(find.text('#')).center.dx,
                tester.getRect(find.text('7')).center.dx,
              );
              expect(
                tester.getRect(find.text('Artist')).left,
                tester.getRect(find.text('Track artist')).left,
              );
              expect(
                tester.getRect(find.text('Time')).right,
                tester.getRect(find.text('3:43')).right,
              );
              if (viewport.width == 1000) {
                await expectLater(
                  find.byType(Scaffold),
                  matchesGoldenFile(
                    'goldens/adaptive_track_number_${geometry.number.toInt()}.png',
                  ),
                );
              }
            }
            expect(tester.takeException(), isNull);
          }
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets('200 percent text keeps duration and actions without overflow', (
    tester,
  ) async {
    await render(tester, 320, scaler: const TextScaler.linear(2));
    expect(find.text('3:43'), findsOneWidget);
    expect(find.byType(IconButton), findsOneWidget);
    expect(tester.getRect(find.text('3:43')).bottom, lessThan(600));
    expect(tester.takeException(), isNull);
    final mode = tester
        .widget<TrackRowModeScope>(find.byType(TrackRowModeScope))
        .mode;
    expect(mode, TrackRowMode.compact);
  });

  testWidgets(
    'remote hour-long track keeps its label and duration in a narrow pane',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(320, 600));
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: AdaptiveTrackRow(
              title: 'Long remote song',
              artist: 'A long artist name',
              album: 'A long album name',
              duration: 36123,
              isRemote: true,
              actionExtent: 96,
              actions: SizedBox(width: 96, height: 48),
            ),
          ),
        ),
      );
      expect(find.text('10:02:03'), findsOneWidget);
      expect(find.byKey(RemoteSourceIndicator.semanticsKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rows and headings share overridden number spacing and padding', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1000, 600));
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Column(
            children: [
              AdaptiveTrackHeader(
                leadingExtent: 32,
                leadingGap: 6,
                actionExtent: 96,
                padding: EdgeInsetsDirectional.only(start: 8, end: 4),
              ),
              AdaptiveTrackRow(
                title: 'Title value',
                artist: 'Artist value',
                album: 'Album value',
                leadingExtent: 32,
                leadingGap: 6,
                actionExtent: 96,
                duration: 36123,
                padding: EdgeInsetsDirectional.only(start: 8, end: 4),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getRect(find.text('Artist')).left,
      tester.getRect(find.text('Artist value')).left,
    );
    expect(
      tester.getRect(find.text('Album')).left,
      tester.getRect(find.text('Album value')).left,
    );
    expect(
      tester.getRect(find.text('Time')).right,
      tester.getRect(find.text('10:02:03')).right,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 800.0, 1000.0]) {
    testWidgets('adaptive row golden at width $width', (tester) async {
      await render(tester, width);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/adaptive_track_row_${width.toInt()}.png'),
      );
    });
  }

  testWidgets('unknown duration is visible alongside supplied actions', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 600));
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: AdaptiveTrackRow(
            title: 'Unknown',
            onTap: () {
              taps++;
            },
            actions: IconButton(
              onPressed: () {},
              icon: const Icon(Icons.more_horiz),
            ),
          ),
        ),
      ),
    );
    expect(find.text('--:--'), findsOneWidget);
    await tester.tap(find.text('Unknown'));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
}
