import 'package:flutter/widgets.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_screen.dart';

/// Compatibility wrapper for callers that still refer to the original route
/// screen. All required library setup now uses the shared rebuild experience.
class InitialServerSyncScreen extends StatelessWidget {
  const InitialServerSyncScreen({super.key});

  @override
  Widget build(BuildContext context) => const RequiredLibraryRebuildScreen(
    reason: RequiredLibraryRebuildReason.initialLogin,
  );
}
