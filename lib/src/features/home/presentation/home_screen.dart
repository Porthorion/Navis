import 'package:flutter/material.dart';

/// Temporary home screen used for Phase 0 bootstrap verification.
class HomeScreen extends StatelessWidget {
  /// Creates a new [HomeScreen].
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('Navis Phase 0 Bootstrap'),
      ),
    );
  }
}
