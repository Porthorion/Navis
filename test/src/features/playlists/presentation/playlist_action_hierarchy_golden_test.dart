import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildActions({required bool primaryPlay}) {
    return MaterialApp(
      theme: ThemeData(colorSchemeSeed: const Color(0xFF6750A4)),
      home: Scaffold(
        body: Center(
          child: Wrap(
            spacing: 8,
            children: <Widget>[
              if (primaryPlay)
                FilledButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: () {},
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: const Text('Play'),
                ),
              FilledButton.tonalIcon(
                onPressed: () {},
                icon: const Icon(Icons.shuffle_outlined),
                label: const Text('Shuffle'),
              ),
              FilledButton.tonalIcon(
                onPressed: () {},
                icon: const Icon(Icons.download_outlined),
                label: const Text('Download'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('playlist action hierarchy before: Play is visually equal', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 120));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildActions(primaryPlay: false));

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/playlist_actions_before.png'),
    );
  });

  testWidgets('playlist action hierarchy: Play is the single primary action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 120));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildActions(primaryPlay: true));

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/playlist_actions_after.png'),
    );
  });
}
