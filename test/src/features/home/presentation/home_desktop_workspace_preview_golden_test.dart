import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool panels}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(Colors.deepPurple),
          home: Scaffold(body: _Preview(panels: panels)),
        ),
      );

  testWidgets('home desktop before uses page panels', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, panels: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/home_desktop_workspace_before.png'),
    );
  });

  testWidgets('home desktop after uses continuous sections', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, panels: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/home_desktop_workspace_after.png'),
    );
  });
}

class _Preview extends StatelessWidget {
  const new({required this.panels});
  final bool panels;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    Widget section(String title, Color art) => Container(
      margin: panels
          ? const EdgeInsets.fromLTRB(16, 12, 16, 0)
          : const EdgeInsets.fromLTRB(24, 14, 24, 0),
      padding: panels ? const EdgeInsets.all(16) : EdgeInsets.zero,
      decoration: panels
          ? BoxDecoration(
              color: c.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              for (var i = 0; i < 5; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Container(
                    width: 94,
                    height: 78,
                    decoration: BoxDecoration(
                      color: art.withValues(alpha: 1 - i * .09),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
    return ColoredBox(
      color: c.surface,
      child: Column(
        children: <Widget>[
          const SizedBox(height: 12),
          section('Recently added', const Color(0xFFE16734)),
          section('Made for You', const Color(0xFF6F62B8)),
          section('Recently played', const Color(0xFF27818C)),
        ],
      ),
    );
  }
}
