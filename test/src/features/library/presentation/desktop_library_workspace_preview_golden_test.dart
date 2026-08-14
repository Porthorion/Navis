import 'package:flutter/material.dart';
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
              ? const _IntegratedLibraryWorkspace()
              : const _CardBasedLibraryWorkspace(),
        ),
      ),
    );
  }

  testWidgets('desktop library before is a floating page panel', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPreview(tester, integratedWorkspace: false);

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/desktop_library_workspace_before.png'),
    );
  });

  testWidgets('desktop library uses an integrated browsing workspace', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPreview(tester, integratedWorkspace: true);

    expect(find.text('Library'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('libraryWorkspace')), findsOne);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/desktop_library_workspace_after.png'),
    );
  });
}

class _CardBasedLibraryWorkspace extends StatelessWidget {
  const _CardBasedLibraryWorkspace();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 4,
          child: ColoredBox(color: colors.surfaceContainerLow),
        ),
        Expanded(
          child: ColoredBox(
            color: colors.surface,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _Panel(
                child: _LibraryRows(color: colors.surfaceContainer),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _IntegratedLibraryWorkspace extends StatelessWidget {
  const _IntegratedLibraryWorkspace();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        ColoredBox(
          color: colors.surfaceContainerLow,
          child: SizedBox(
            width: 64,
            child: Column(
              children: const <Widget>[
                SizedBox(height: 28),
                Icon(Icons.home_outlined),
                SizedBox(height: 28),
                Icon(Icons.library_music_outlined),
                SizedBox(height: 28),
                Icon(Icons.search),
                SizedBox(height: 28),
                Icon(Icons.settings_outlined),
              ],
            ),
          ),
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: colors.outlineVariant.withValues(alpha: 0.35),
        ),
        Expanded(
          child: ColoredBox(
            color: colors.surface,
            child: Column(
              children: <Widget>[
                Material(
                  color: colors.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                    child: Row(
                      children: <Widget>[
                        Text(
                          'Library',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Albums',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: colors.outlineVariant.withValues(alpha: 0.35),
                ),
                Expanded(
                  child: _LibraryRows(
                    key: const ValueKey<String>('libraryWorkspace'),
                    color: colors.surface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _LibraryRows extends StatelessWidget {
  const _LibraryRows({required this.color, super.key});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ColoredBox(
      color: color,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        children: <Widget>[
          Text('Recently added', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          for (final album in <(String, String, Color)>[
            ('Imaginal Disk', 'Magdalena Bay', const Color(0xFFE16734)),
            ('Bloom', 'Beach House', const Color(0xFF6F62B8)),
            ('Promises', 'Floating Points', const Color(0xFF27818C)),
            ('In Rainbows', 'Radiohead', const Color(0xFFB85C65)),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: album.$3,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(album.$1),
                      Text(album.$2, style: TextStyle(color: muted)),
                    ],
                  ),
                  const Spacer(),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
