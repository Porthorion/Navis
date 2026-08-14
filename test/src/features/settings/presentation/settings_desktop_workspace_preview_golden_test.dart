import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, bool groupedPanels) =>
      tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(Colors.deepPurple),
          home: Scaffold(body: _Preview(groupedPanels: groupedPanels)),
        ),
      );

  testWidgets('settings desktop before uses stacked group panels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_desktop_workspace_before.png'),
    );
  });

  testWidgets('settings desktop after uses a continuous preference list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_desktop_workspace_after.png'),
    );
  });
}

class _Preview extends StatelessWidget {
  const _Preview({required this.groupedPanels});

  final bool groupedPanels;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final sections =
        <
          ({
            String group,
            List<({IconData icon, String title, String subtitle})> rows,
          })
        >[
          (
            group: 'Connection',
            rows: <({IconData icon, String title, String subtitle})>[
              (
                icon: Icons.storage_outlined,
                title: 'Server',
                subtitle: 'Connection and account',
              ),
            ],
          ),
          (
            group: 'Storage',
            rows: <({IconData icon, String title, String subtitle})>[
              (
                icon: Icons.folder_copy_outlined,
                title: 'Cache',
                subtitle: 'Storage and cleanup',
              ),
              (
                icon: Icons.download_outlined,
                title: 'Downloads',
                subtitle: 'Offline listening',
              ),
            ],
          ),
          (
            group: 'Playback',
            rows: <({IconData icon, String title, String subtitle})>[
              (
                icon: Icons.graphic_eq_outlined,
                title: 'Playback',
                subtitle: 'Audio and queue behavior',
              ),
              (
                icon: Icons.palette_outlined,
                title: 'Appearance',
                subtitle: 'Theme and interface',
              ),
            ],
          ),
        ];

    return ColoredBox(
      color: colors.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        children: <Widget>[
          if (groupedPanels) ...<Widget>[
            Text(
              'Settings',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'Desktop workspace controls and app preferences',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
          ],
          for (final section in sections)
            _SettingsGroup(
              title: section.group,
              rows: section.rows,
              panel: groupedPanels,
            ),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    required this.title,
    required this.rows,
    required this.panel,
  });

  final String title;
  final List<({IconData icon, String title, String subtitle})> rows;
  final bool panel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        for (final row in rows)
          SizedBox(
            height: 60,
            child: Row(
              children: <Widget>[
                Icon(row.icon, color: colors.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(row.title),
                      Text(
                        row.subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: panel
          ? Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(18),
              ),
              child: content,
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: content,
            ),
    );
  }
}
