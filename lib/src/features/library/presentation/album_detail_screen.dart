import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/placeholder_screen.dart';

class AlbumDetailScreen extends StatelessWidget {
  const AlbumDetailScreen({required this.albumId, super.key});

  final String albumId;

  @override
  Widget build(BuildContext context) {
    return PlaceholderScreen(
      title: 'Album Detail',
      subtitle: 'Album ID: $albumId',
    );
  }
}
