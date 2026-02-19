import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/placeholder_screen.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Downloads',
      subtitle: 'Phase 8: download queue and offline storage.',
    );
  }
}
