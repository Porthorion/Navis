import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/placeholder_screen.dart';

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Playlists',
      subtitle: 'Phase 7: playlists list.',
    );
  }
}
