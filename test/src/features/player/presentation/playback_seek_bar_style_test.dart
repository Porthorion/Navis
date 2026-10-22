import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/playback_seek_bar_style.dart';
import 'package:navis/src/providers/app_providers.dart'
    show playbackPositionProvider, playerStateProvider;

void main() {
  test('buffered seek value is track keyed and clamped to duration', () {
    expect(
      resolveBufferedSeekValue(
        currentSongId: 'song-1',
        bufferState: const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration(seconds: 90),
        ),
        duration: const Duration(seconds: 240),
      ),
      90000,
    );
    expect(
      resolveBufferedSeekValue(
        currentSongId: 'song-1',
        bufferState: const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration(seconds: 300),
        ),
        duration: const Duration(seconds: 240),
      ),
      240000,
    );
  });

  test('buffered seek value hides stale, empty, and unknown timelines', () {
    expect(
      resolveBufferedSeekValue(
        currentSongId: 'song-2',
        bufferState: const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration(seconds: 90),
        ),
        duration: const Duration(seconds: 240),
      ),
      isNull,
    );
    expect(
      resolveBufferedSeekValue(
        currentSongId: 'song-1',
        bufferState: const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration.zero,
        ),
        duration: const Duration(seconds: 240),
      ),
      isNull,
    );
    expect(
      resolveBufferedSeekValue(
        currentSongId: 'song-1',
        bufferState: const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration(seconds: 90),
        ),
        duration: Duration.zero,
      ),
      isNull,
    );
  });

  group('ahead range', () {
    const duration = Duration(seconds: 240);
    PlaybackBufferState state({
      String songId = 'song-1',
      Duration? start = const Duration(seconds: 120),
      Duration? end = const Duration(seconds: 150),
    }) => PlaybackBufferState(
      songId: songId,
      bufferedPosition: const Duration(seconds: 60),
      aheadStart: start,
      aheadEnd: end,
    );

    ({double start, double end})? resolve(
      PlaybackBufferState bufferState, {
      String? songId = 'song-1',
      Duration length = duration,
    }) => resolveAheadSeekRange(
      currentSongId: songId,
      bufferState: bufferState,
      duration: length,
    );

    test('is track keyed and clamped to the duration', () {
      expect(resolve(state()), (start: 120000.0, end: 150000.0));
      expect(resolve(state(end: const Duration(seconds: 999))), (
        start: 120000.0,
        end: 240000.0,
      ));
    });

    test('is null when not detached, stale or unknown', () {
      expect(resolve(state(start: null, end: null)), isNull);
      expect(resolve(state(songId: 'song-2')), isNull);
      expect(resolve(state(), songId: null), isNull);
      expect(resolve(state(), length: Duration.zero), isNull);
      expect(
        resolve(state(start: const Duration(seconds: 150))),
        isNull,
        reason: 'an empty range draws nothing',
      );
      expect(
        resolve(state(start: const Duration(seconds: 300))),
        isNull,
        reason: 'a range clamped to nothing draws nothing',
      );
    });

    // Draws the bar with the thumb at [thumb]: inside the cached range (30 s),
    // in the gap (90 s) and inside the ahead range (135 s).
    Future<void> pumpBar(
      WidgetTester tester, {
      required double thumb,
      TextDirection direction = TextDirection.ltr,
      GlobalKey? boundary,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: boundary,
                  child: SizedBox(
                    width: 400,
                    height: 48,
                    child: Builder(
                      builder: (context) => SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackShape: resolveAheadTrackShape(
                            context,
                            currentSongId: 'song-1',
                            bufferState: state(),
                            duration: duration,
                            max: 240000,
                          ),
                        ),
                        child: Slider(
                          value: thumb * 1000,
                          max: 240000,
                          secondaryTrackValue: 60000,
                          secondaryActiveColor: resolveBufferedSeekColor(
                            context,
                          ),
                          onChanged: (_) {},
                        ),
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

    RenderBox sliderBox(WidgetTester tester) =>
        tester.renderObject<RenderBox>(find.byType(Slider));

    testWidgets('the shape gets the range and wraps the theme shape', (
      tester,
    ) async {
      await pumpBar(tester, thumb: 30);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.secondaryTrackValue, 60000);
      final shape = SliderTheme.of(tester.element(find.byType(Slider)))
          .trackShape;
      expect(shape, isA<AheadRangeTrackShape>());
      shape! as AheadRangeTrackShape;
      expect((shape as AheadRangeTrackShape).start, 120000);
      expect(shape.end, 150000);
      expect(shape.delegate, isA<RoundedRectSliderTrackShape>());
    });

    // The rounded rects the shape draws with [color], for a thumb at [thumbX].
    List<Rect> aheadRects(
      WidgetTester tester, {
      required double thumbX,
      TextDirection direction = TextDirection.ltr,
      double start = 120000,
      double end = 150000,
    }) {
      final box = sliderBox(tester);
      final theme = SliderThemeData.fromPrimaryColors(
        primaryColor: const Color(0xFF0000FF),
        primaryColorDark: const Color(0xFF000099),
        primaryColorLight: const Color(0xFF9999FF),
        valueIndicatorTextStyle: const TextStyle(),
      ).copyWith(secondaryActiveTrackColor: const Color(0xFFFF0000));
      final canvas = TestRecordingCanvas();
      AheadRangeTrackShape(
        delegate: const RoundedRectSliderTrackShape(),
        start: start,
        end: end,
        max: 240000,
      ).paint(
        TestRecordingPaintingContext(canvas),
        Offset.zero,
        parentBox: box,
        sliderTheme: theme,
        enableAnimation: kAlwaysCompleteAnimation,
        thumbCenter: Offset(thumbX, 24),
        isEnabled: true,
        textDirection: direction,
      );
      return [
        for (final call in canvas.invocations)
          if (call.invocation.memberName == #drawRRect &&
              (call.invocation.positionalArguments[1] as Paint).color ==
                  const Color(0xFFFF0000))
            (call.invocation.positionalArguments[0] as RRect).outerRect,
      ];
    }

    testWidgets('paints the ahead segment, from the thumb when inside it', (
      tester,
    ) async {
      await pumpBar(tester, thumb: 30);
      // The 400 px track maps 240 s; 120 s to 150 s is 200 to 250 px of it.
      final track = const RoundedRectSliderTrackShape().getPreferredRect(
        parentBox: sliderBox(tester),
        sliderTheme: SliderThemeData.fromPrimaryColors(
          primaryColor: const Color(0xFF0000FF),
          primaryColorDark: const Color(0xFF000099),
          primaryColorLight: const Color(0xFF9999FF),
          valueIndicatorTextStyle: const TextStyle(),
        ),
        isEnabled: true,
      );
      double at(double ms) => track.left + track.width * ms / 240000;
      // Thumb before the range: the whole range. In the gap: the same.
      for (final thumbX in [at(30000), at(90000)]) {
        final rect = aheadRects(tester, thumbX: thumbX).single;
        expect(rect.left, closeTo(at(120000), 0.01));
        expect(rect.right, closeTo(at(150000), 0.01));
        expect(rect.height, track.height);
      }
      // Thumb inside the range: from the thumb on.
      final inside = aheadRects(tester, thumbX: at(135000)).single;
      expect(inside.left, closeTo(at(135000), 0.01));
      expect(inside.right, closeTo(at(150000), 0.01));
      // Thumb past the range: nothing to draw.
      expect(aheadRects(tester, thumbX: at(200000)), isEmpty);
    });

    testWidgets('mirrors in a right-to-left layout', (tester) async {
      await pumpBar(tester, thumb: 30, direction: TextDirection.rtl);
      final track = const RoundedRectSliderTrackShape().getPreferredRect(
        parentBox: sliderBox(tester),
        sliderTheme: SliderThemeData.fromPrimaryColors(
          primaryColor: const Color(0xFF0000FF),
          primaryColorDark: const Color(0xFF000099),
          primaryColorLight: const Color(0xFF9999FF),
          valueIndicatorTextStyle: const TextStyle(),
        ),
        isEnabled: true,
      );
      double at(double ms) => track.right - track.width * ms / 240000;
      // The thumb is at the right end (the start of the song).
      final rect = aheadRects(
        tester,
        thumbX: track.right,
        direction: TextDirection.rtl,
      ).single;
      expect(rect.left, closeTo(at(150000), 0.01));
      expect(rect.right, closeTo(at(120000), 0.01));
      // A thumb inside the range clips the side the thumb has passed.
      final inside = aheadRects(
        tester,
        thumbX: at(135000),
        direction: TextDirection.rtl,
      ).single;
      expect(inside.left, closeTo(at(150000), 0.01));
      expect(inside.right, closeTo(at(135000), 0.01));
    });

    // With NAVIS_SEEK_BAR_SHOTS=<dir> the three thumb positions are saved as
    // PNGs for the visual check; otherwise only the paint is asserted.
    testWidgets('renders the three thumb positions', (tester) async {
      final dir = Platform.environment['NAVIS_SEEK_BAR_SHOTS'];
      for (final (name, thumb) in [
        ('thumb_in_cached', 30.0),
        ('thumb_in_gap', 90.0),
        ('thumb_in_ahead', 135.0),
      ]) {
        final boundary = GlobalKey();
        await pumpBar(tester, thumb: thumb, boundary: boundary);
        if (dir == null) continue;
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 3);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }
    });
  });

  PlaybackSnapshot snapshot({Duration? pendingSeek}) => PlaybackSnapshot(
    queueSongIds: const <String>['song-1'],
    currentSongId: 'song-1',
    currentIndex: 0,
    playing: true,
    processingState: AudioProcessingState.ready,
    position: Duration.zero,
    duration: const Duration(minutes: 4),
    bufferedPosition: Duration.zero,
    shuffleMode: AudioServiceShuffleMode.none,
    repeatMode: AudioServiceRepeatMode.one,
    pendingSeekPosition: pendingSeek,
  );

  testWidgets('a finished seek never freezes the shown position', (
    tester,
  ) async {
    // The parent's snapshot can still carry the seek after the handler has
    // cleared it (it rebuilt for nothing else, e.g. under Repeat One). The
    // bar must follow the live position, not stay on the seek target.
    final positions = StreamController<Duration>();
    addTearDown(positions.close);
    final stale = snapshot(pendingSeek: const Duration(seconds: 60));
    final container = ProviderContainer(
      overrides: [
        playbackPositionProvider.overrideWith((ref) => positions.stream),
        _live.overrideWith(
          () =>
              _LiveSnapshot(snapshot(pendingSeek: const Duration(seconds: 60))),
        ),
        playerStateProvider.overrideWith((ref) => ref.watch(_live)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) =>
                Text('${watchDisplayedPlaybackPosition(ref, stale).inSeconds}'),
          ),
        ),
      ),
    );
    expect(find.text('60'), findsOneWidget);
    // The seek completes: the handler clears it and playback moves on.
    container.read(_live.notifier).current = snapshot();
    positions.add(const Duration(seconds: 61));
    await tester.pump();
    await tester.pump();
    expect(find.text('61'), findsOneWidget);
    positions.add(const Duration(seconds: 65));
    await tester.pump();
    await tester.pump();
    expect(find.text('65'), findsOneWidget);
  });
}

final _live = NotifierProvider<_LiveSnapshot, PlaybackSnapshot>(
  () => throw UnimplementedError('overridden in the test'),
);

class _LiveSnapshot extends Notifier<PlaybackSnapshot> {
  new(this._initial);

  final PlaybackSnapshot _initial;

  @override
  PlaybackSnapshot build() => _initial;

  set current(PlaybackSnapshot value) => state = value;
}
