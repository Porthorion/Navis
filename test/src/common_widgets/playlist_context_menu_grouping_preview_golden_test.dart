import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool grouped}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(body: _PlaylistTrackMenuPreview(grouped: grouped)),
      ),
    );
  }

  testWidgets('playlist track menu before mixes removal into utility actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, grouped: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/playlist_context_menu_grouping_before.png'),
    );
  });

  testWidgets(
    'playlist track menu after keeps removal in a final action group',
    (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester, grouped: true);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/playlist_context_menu_grouping_after.png'),
      );
    },
  );
}

class _PlaylistTrackMenuPreview extends StatelessWidget {
  const _PlaylistTrackMenuPreview({required this.grouped});

  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const transportActions = <Widget>[
      _ActionTile(icon: Icons.play_arrow_outlined, label: 'Play now'),
      _ActionTile(icon: Icons.queue_music_outlined, label: 'Add to queue'),
      _ActionTile(icon: Icons.playlist_add_outlined, label: 'Play next'),
    ];
    const utilityActions = <Widget>[
      _ActionTile(icon: Icons.person_outline, label: 'Go to artist'),
      _ActionTile(icon: Icons.album_outlined, label: 'Go to album'),
      _ActionTile(icon: Icons.playlist_add, label: 'Add to playlist'),
      _ActionTile(icon: Icons.download_outlined, label: 'Download'),
    ];
    final removeTrack = _ActionTile(
      icon: Icons.remove_circle_outline,
      label: 'Remove from playlist',
      color: colors.error,
    );

    final actions = <Widget>[
      ...transportActions,
      if (grouped) const Divider(height: 1),
      if (!grouped) removeTrack,
      ...utilityActions,
      if (grouped) const Divider(height: 1),
      if (grouped) removeTrack,
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
