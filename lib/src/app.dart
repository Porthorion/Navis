import 'package:flutter/material.dart';
import 'package:navis/src/routing/app_router.dart';

/// Root application widget for Navis.
class NavisApp extends StatelessWidget {
  /// Creates a new [NavisApp].
  const NavisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Navis',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      routerConfig: appRouter,
    );
  }
}
