import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool reducedMotion}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(body: _PanelPreview(reducedMotion: reducedMotion)),
      ),
    );
  }

  testWidgets('wide panel before animates through a travel frame', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(840, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, reducedMotion: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/now_playing_wide_panel_motion_before.png'),
    );
  });

  testWidgets('wide panel after settles directly with reduced motion', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(840, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, reducedMotion: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/now_playing_wide_panel_motion_after.png'),
    );
  });
}

class _PanelPreview extends StatelessWidget {
  const new({required this.reducedMotion});

  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final panel = Material(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: <Widget>[
                const Icon(Icons.arrow_back),
                const SizedBox(width: 12),
                Text(
                  'Queue',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: colors.outlineVariant.withValues(alpha: .4),
          ),
          Expanded(
            child: ListView(
              children: <Widget>[
                for (var i = 0; i < 5; i++)
                  ListTile(
                    leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: colors.primary.withValues(
                        alpha: .16 + i * .03,
                      ),
                    ),
                    title: Text('Queued track ${i + 1}'),
                    subtitle: const Text('Artist'),
                    trailing: const Icon(Icons.drag_handle),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: Stack(
        children: <Widget>[
          Center(
            child: Text(
              'Now Playing',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: reducedMotion ? .26 : .15),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Opacity(
              opacity: reducedMotion ? 1 : .55,
              child: FractionalTranslation(
                translation: Offset(0, reducedMotion ? 0 : .34),
                child: SizedBox(height: 360, child: panel),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
