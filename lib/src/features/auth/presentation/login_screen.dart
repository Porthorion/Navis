import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/placeholder_screen.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Login',
      subtitle: 'Phase 2: server URL, username and password form.',
    );
  }
}
