import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/presentation/desktop_volume_slider.dart';

void main() {
  testWidgets('exposes named volume and mute controls to accessibility', (
    tester,
  ) async {
    var muted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopVolumeSlider(
            volume: 0.37,
            semanticLabel: 'Playback volume',
            muteTooltip: 'Mute playback',
            unmuteTooltip: 'Unmute playback',
            onChanged: (_) {},
            onChangeEnd: (_) {},
            onMuteToggle: () => muted = true,
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Playback volume'), findsOneWidget);
    expect(find.byTooltip('Mute playback'), findsOneWidget);
    await tester.tap(find.byTooltip('Mute playback'));
    expect(muted, isTrue);
  });

  testWidgets('reports the final value when slider interaction completes', (
    tester,
  ) async {
    double? completedValue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopVolumeSlider(
            volume: 0.5,
            semanticLabel: 'Playback volume',
            muteTooltip: 'Mute playback',
            unmuteTooltip: 'Unmute playback',
            onChanged: (_) {},
            onChangeEnd: (value) => completedValue = value,
            onMuteToggle: () {},
          ),
        ),
      ),
    );

    final slider = find.byType(Slider);
    final center = tester.getCenter(slider);
    await tester.dragFrom(center, const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(completedValue, isNotNull);
    expect(completedValue, greaterThan(0.5));
  });
}
