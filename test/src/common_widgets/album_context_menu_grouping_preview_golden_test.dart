import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool grouped}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(body: _AlbumMenuPreview(grouped: grouped)),
      ),
    );
  }

  testWidgets(
    'album context menu before blends download removal into actions',
    (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester, grouped: false);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/album_context_menu_grouping_before.png'),
      );
    },
  );

  testWidgets('album context menu after separates download removal', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, grouped: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/album_context_menu_grouping_after.png'),
    );
  });
}

class _AlbumMenuPreview extends StatelessWidget {
  const _AlbumMenuPreview({required this.grouped});

  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: colors.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const _ActionTile(
                  icon: Icons.open_in_new_outlined,
                  label: 'Open album',
                ),
                const _ActionTile(
                  icon: Icons.play_arrow_outlined,
                  label: 'Play album',
                ),
                const _ActionTile(
                  icon: Icons.queue_music_outlined,
                  label: 'Add to Queue',
                ),
                const _ActionTile(icon: Icons.favorite_border, label: 'Like'),
                if (grouped) const Divider(height: 1),
                _ActionTile(
                  icon: Icons.delete_outline,
                  label: 'Remove download',
                  color: colors.error,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 52,
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
    );
  }
}
