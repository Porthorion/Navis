import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/placeholder_screen.dart';

class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Search',
      subtitle: 'Phase 6: live Subsonic search.',
    );
  }
}
