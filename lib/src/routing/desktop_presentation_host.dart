import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';

/// Stable root boundary for desktop presentation-mode changes.
///
/// The routed child is deliberately kept as the same subtree while the window
/// controller changes modes, preserving GoRouter branch navigators, overlays,
/// searches, and playback-owned state.
class DesktopPresentationHost extends ConsumerWidget {
  const DesktopPresentationHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(desktopWindowModeProvider);
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      key: const ValueKey<String>('desktopPresentationHost'),
      container: true,
      label: mode == DesktopWindowMode.miniPlayer
          ? l10n.desktopMiniPlayerTitle
          : l10n.desktopViewTitle,
      child: child,
    );
  }
}
