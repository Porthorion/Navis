import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool grouped}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(body: _SongMenuPreview(grouped: grouped)),
      ),
    );
  }

  testWidgets('song context menu before keeps all actions in one flat list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, grouped: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/song_context_menu_grouping_before.png'),
    );
  });

  testWidgets('song context menu after separates action groups', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, grouped: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/song_context_menu_grouping_after.png'),
    );
  });
}

class _SongMenuPreview extends StatelessWidget {
  const _SongMenuPreview({required this.grouped});

  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final actions = <Widget>[
      const _ActionTile(icon: Icons.play_arrow_outlined, label: 'Play now'),
      const _ActionTile(
        icon: Icons.queue_music_outlined,
        label: 'Add to Queue',
      ),
      const _ActionTile(
        icon: Icons.playlist_add_outlined,
        label: 'Play next',
      ),
      if (grouped) const Divider(height: 1),
      const _ActionTile(icon: Icons.favorite_border, label: 'Like'),
      const _ActionTile(icon: Icons.star_outline, label: 'Rating'),
      const _ActionTile(icon: Icons.person_outline, label: 'Go to artist'),
      const _ActionTile(icon: Icons.album_outlined, label: 'Go to album'),
      const _ActionTile(icon: Icons.playlist_add, label: 'Add to playlist'),
      if (grouped) const Divider(height: 1),
      _ActionTile(
        icon: Icons.delete_outline,
        label: 'Remove download',
        color: colors.error,
      ),
    ];
    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: colors.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: actions),
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
