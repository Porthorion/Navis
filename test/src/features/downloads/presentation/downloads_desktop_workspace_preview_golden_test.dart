import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, bool commandStrip) =>
      tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(Colors.deepPurple),
          home: Scaffold(body: _Preview(commandStrip: commandStrip)),
        ),
      );

  testWidgets('downloads desktop before separates app bar, tabs, and search', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/downloads_desktop_workspace_before.png'),
    );
  });

  testWidgets('downloads desktop after uses a unified command strip', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/downloads_desktop_workspace_after.png'),
    );
  });
}

class _Preview extends StatelessWidget {
  const new({required this.commandStrip});

  final bool commandStrip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tabs = Row(
      mainAxisSize: MainAxisSize.min,
      children: const <Widget>[
        _Tab(label: 'Queue', selected: true),
        _Tab(label: 'Downloaded'),
        _Tab(label: 'Settings'),
      ],
    );
    final search = Container(
      width: 244,
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.search, size: 18),
          const SizedBox(width: 8),
          Text(
            'Search queue',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );

    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: <Widget>[
          if (commandStrip)
            Container(
              height: 72,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                border: Border(
                  bottom: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .35),
                  ),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.arrow_back,
                    color: colors.onSurfaceVariant,
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Downloads',
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 28),
                  Expanded(
                    child: ClipRect(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: tabs,
                        ),
                      ),
                    ),
                  ),
                  search,
                ],
              ),
            )
          else ...<Widget>[
            Container(
              height: 68,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              color: colors.surfaceContainer,
              alignment: Alignment.centerLeft,
              child: Text(
                'Downloads',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Container(
              height: 52,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: tabs,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Align(alignment: Alignment.centerLeft, child: search),
            ),
          ],
          const Expanded(child: _Rows()),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const new({required this.label, this.selected = false});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: selected
            ? Border(bottom: BorderSide(color: colors.primary, width: 3))
            : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? colors.primary : colors.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

class _Rows extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      itemCount: 5,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: colors.outlineVariant.withValues(alpha: .35),
      ),
      itemBuilder: (context, index) => SizedBox(
        height: 62,
        child: Row(
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: .18 + index * .035),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Downloaded track ${index + 1}'),
                  Text(
                    'Artist · MP3 · 8.4 MB',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const Icon(Icons.more_horiz),
          ],
        ),
      ),
    );
  }
}
