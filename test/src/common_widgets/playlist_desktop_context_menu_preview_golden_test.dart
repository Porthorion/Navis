import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool desktopMenu}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(
          body: _PlaylistContextMenuPreview(desktopMenu: desktopMenu),
        ),
      ),
    );
  }

  testWidgets('desktop playlist actions before use a phone bottom sheet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, desktopMenu: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/playlist_desktop_context_menu_before.png'),
    );
  });

  testWidgets('desktop playlist actions after use an anchored context menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, desktopMenu: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/playlist_desktop_context_menu_after.png'),
    );
  });
}

class _PlaylistContextMenuPreview extends StatelessWidget {
  const _PlaylistContextMenuPreview({required this.desktopMenu});

  final bool desktopMenu;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final menu = _ActionMenu(colors: colors, desktopMenu: desktopMenu);
    return ColoredBox(
      color: colors.surface,
      child: Stack(
        children: <Widget>[
          const Positioned(
            left: 56,
            top: 48,
            right: 56,
            child: _PlaylistRows(),
          ),
          if (desktopMenu)
            Positioned(right: 96, top: 112, child: menu)
          else
            Align(alignment: Alignment.bottomCenter, child: menu),
        ],
      ),
    );
  }
}

class _PlaylistRows extends StatelessWidget {
  const _PlaylistRows();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const <Widget>[
        Text('Roadtrip Mix', style: TextStyle(fontSize: 24)),
        SizedBox(height: 20),
        _TrackRow(title: 'Northern Lights', active: true),
        _TrackRow(title: 'Silver Lining'),
        _TrackRow(title: 'Night Drive'),
      ],
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.title, this.active = false});

  final String title;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: active ? colors.primary.withValues(alpha: 0.1) : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            active ? Icons.graphic_eq : Icons.music_note_outlined,
            color: active ? colors.primary : null,
          ),
          const SizedBox(width: 14),
          Expanded(child: Text(title)),
          const Icon(Icons.more_vert),
        ],
      ),
    );
  }
}

class _ActionMenu extends StatelessWidget {
  const _ActionMenu({required this.colors, required this.desktopMenu});

  final ColorScheme colors;
  final bool desktopMenu;

  @override
  Widget build(BuildContext context) {
    final entries = <Widget>[
      _ActionRow(
        icon: Icons.play_arrow_outlined,
        label: 'Play now',
        showIcon: !desktopMenu,
      ),
      _ActionRow(
        icon: Icons.queue_music_outlined,
        label: 'Add to queue',
        showIcon: !desktopMenu,
      ),
      _ActionRow(
        icon: Icons.playlist_add_outlined,
        label: 'Play next',
        showIcon: !desktopMenu,
      ),
      const Divider(height: 1),
      _ActionRow(
        icon: Icons.person_outline,
        label: 'Go to artist',
        showIcon: !desktopMenu,
      ),
      _ActionRow(
        icon: Icons.album_outlined,
        label: 'Go to album',
        showIcon: !desktopMenu,
      ),
      _ActionRow(
        icon: Icons.playlist_add,
        label: 'Add to playlist',
        showIcon: !desktopMenu,
      ),
      _ActionRow(
        icon: Icons.download_outlined,
        label: 'Download',
        showIcon: !desktopMenu,
      ),
      const Divider(height: 1),
      _ActionRow(
        icon: Icons.remove_circle_outline,
        label: 'Remove from playlist',
        color: colors.error,
        showIcon: !desktopMenu,
      ),
    ];
    return Material(
      color: colors.surfaceContainerHigh,
      elevation: desktopMenu ? 8 : 0,
      borderRadius: desktopMenu
          ? BorderRadius.circular(12)
          : const BorderRadius.vertical(top: Radius.circular(28)),
      child: SizedBox(
        width: desktopMenu ? 244 : double.infinity,
        child: Column(mainAxisSize: MainAxisSize.min, children: entries),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    this.color,
    this.showIcon = true,
  });

  final IconData icon;
  final String label;
  final Color? color;
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 42,
      dense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: showIcon ? 16 : 12),
      leading: showIcon ? Icon(icon, color: color, size: 20) : null,
      title: Text(label, style: TextStyle(color: color)),
    );
  }
}
