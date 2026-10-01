import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pumpPreview(
    WidgetTester tester, {
    required bool integratedWorkspace,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(
          body: integratedWorkspace
              ? const _IntegratedSearchWorkspace()
              : const _CardBasedSearchWorkspace(),
        ),
      ),
    );
  }

  testWidgets('desktop search before presents floating page cards', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPreview(tester, integratedWorkspace: false);

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/desktop_search_workspace_before.png'),
    );
  });

  testWidgets('desktop search uses an integrated workspace', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPreview(tester, integratedWorkspace: true);

    expect(find.text('Search'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('resultsWorkspace')), findsOne);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/desktop_search_workspace_after.png'),
    );
  });
}

class _CardBasedSearchWorkspace extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: <Widget>[
            _SurfaceCard(
              child: _SearchField(color: colors.surfaceContainerHigh),
            ),
            const SizedBox(height: 12),
            const Expanded(child: _SurfaceCard(child: _ResultRows())),
          ],
        ),
      ),
    );
  }
}

class _IntegratedSearchWorkspace extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: <Widget>[
          Material(
            color: colors.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
              child: Row(
                children: <Widget>[
                  Text(
                    'Search',
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 20),
                  const Expanded(child: _SearchField()),
                ],
              ),
            ),
          ),
          Divider(
            height: 1,
            thickness: 1,
            color: colors.outlineVariant.withValues(alpha: 0.35),
          ),
          const Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 20),
              child: _ResultRows(key: ValueKey<String>('resultsWorkspace')),
            ),
          ),
        ],
      ),
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const new({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _SearchField extends StatelessWidget {
  const new({this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: color ?? Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: <Widget>[
          const Icon(Icons.search),
          const SizedBox(width: 10),
          Text(
            'Search artists, albums, and songs',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultRows extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
          child: Text('Albums', style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final row in <(String, String)>[
          ('Dawn FM', 'The Weeknd'),
          ('Solitude', 'M83'),
          ('The New Abnormal', 'The Strokes'),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colorsFor(row.$1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(row.$1),
                    Text(row.$2, style: TextStyle(color: muted)),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Color colorsFor(String title) => switch (title) {
    'Dawn FM' => const Color(0xFFEF8C44),
    'Solitude' => const Color(0xFF6C5DB8),
    _ => const Color(0xFF27818C),
  };
}
