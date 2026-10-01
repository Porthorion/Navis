import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/desktop_playback_progress.dart';

import '../../helpers/test_theme.dart';

void main() {
  for (final width in [400.0, 220.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('hour labels remain visible at $width / $scale', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: testTheme(),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: width,
                    child: DesktopPlaybackProgress(
                      elapsed: '1:02:03',
                      total: '10:02:03',
                      liveLabel: 'LIVE',
                      seekBar: Slider(value: 0.5, onChanged: (_) {}),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('1:02:03'), findsOneWidget);
        expect(find.text('10:02:03'), findsOneWidget);
        expect(
          find.byKey(
            ValueKey(
              width == 220 || scale == 2
                  ? 'desktopProgressStacked'
                  : 'desktopProgressInline',
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('unknown durations and live radio have distinct presentations', (
    tester,
  ) async {
    Future<void> pump({required bool live}) => tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: DesktopPlaybackProgress(
            elapsed: '--:--',
            total: '--:--',
            liveLabel: 'LIVE',
            isLive: live,
            seekBar: const SizedBox(),
          ),
        ),
      ),
    );
    await pump(live: false);
    expect(find.text('--:--'), findsNWidgets(2));
    await pump(live: true);
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('--:--'), findsNothing);
    expect(find.byKey(const ValueKey('desktopProgressInline')), findsNothing);
  });
}
