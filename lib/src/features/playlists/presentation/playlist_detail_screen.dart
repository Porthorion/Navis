import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/placeholder_screen.dart';

class PlaylistDetailScreen extends StatelessWidget {
  const PlaylistDetailScreen({required this.playlistId, super.key});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    return PlaceholderScreen(
      title: 'Playlist Detail',
      subtitle: 'Playlist ID: $playlistId',
    );
  }
}
