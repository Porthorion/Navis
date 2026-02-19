import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/placeholder_screen.dart';

/// Temporary home screen used for Phase 0 bootstrap verification.
class HomeScreen extends StatelessWidget {
  /// Creates a new [HomeScreen].
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Home',
      subtitle: 'Phase 3: discovery feed and personalized carousels.',
    );
  }
}
