import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/placeholder_screen.dart';

class ArtistDetailScreen extends StatelessWidget {
  const ArtistDetailScreen({required this.artistId, super.key});

  final String artistId;

  @override
  Widget build(BuildContext context) {
    return PlaceholderScreen(
      title: 'Artist Detail',
      subtitle: 'Artist ID: $artistId',
    );
  }
}
