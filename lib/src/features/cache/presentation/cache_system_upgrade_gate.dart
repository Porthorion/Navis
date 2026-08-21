import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/routing/app_router.dart';

/// Prompts profiles created before the rolling-cache contract to clear their
/// recoverable cache. Dismissing is allowed, but does not acknowledge the
/// migration, so the prompt returns on the next launch.
class CacheSystemUpgradeGate extends ConsumerStatefulWidget {
  const CacheSystemUpgradeGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<CacheSystemUpgradeGate> createState() =>
      _CacheSystemUpgradeGateState();
}

class _CacheSystemUpgradeGateState
    extends ConsumerState<CacheSystemUpgradeGate> {
  bool _dialogVisible = false;
  bool _dismissedForSession = false;

  @override
  Widget build(BuildContext context) {
    // Unconfigured installs have no persisted library to migrate. Besides
    // avoiding needless database initialization on Login, this lets the
    // existing authentication bootstrap remain database-free.
    final hasConfiguredServer =
        ref.watch(serverConfigStateProvider).asData?.value != null;
    final needsUpgrade = hasConfiguredServer
        ? ref.watch(cacheSystemUpgradeNeededProvider)
        : const AsyncData<bool>(false);
    if (needsUpgrade.asData?.value == true &&
        !_dialogVisible &&
        !_dismissedForSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showUpgradeDialog();
      });
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        widget.child,
        if (_dialogVisible)
          _CacheSystemUpgradeDialog(
            onDismiss: _dismissForSession,
            onReset: _resetCacheSystem,
          ),
      ],
    );
  }

  void _showUpgradeDialog() {
    if (_dialogVisible || _dismissedForSession) return;
    setState(() => _dialogVisible = true);
  }

  void _dismissForSession() {
    setState(() {
      _dialogVisible = false;
      _dismissedForSession = true;
    });
  }

  void _resetCacheSystem() {
    setState(() {
      _dialogVisible = false;
      _dismissedForSession = true;
    });
    ref
        .read(appRouterProvider)
        .go(
          requiredLibraryRebuildRoute(
            RequiredLibraryRebuildReason.cacheUpgrade,
          ),
        );
  }
}

class _CacheSystemUpgradeDialog extends StatelessWidget {
  const _CacheSystemUpgradeDialog({
    required this.onDismiss,
    required this.onReset,
  });

  final VoidCallback onDismiss;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDismiss,
          child: const ColoredBox(color: Colors.black54),
        ),
        Center(
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            namesRoute: true,
            label: l10n.cacheSystemUpgradeTitle,
            child: AlertDialog(
              title: Text(l10n.cacheSystemUpgradeTitle),
              content: Text(l10n.cacheSystemUpgradeBody),
              actions: <Widget>[
                TextButton(
                  onPressed: onDismiss,
                  child: Text(l10n.cacheSystemUpgradeDismiss),
                ),
                FilledButton(
                  onPressed: onReset,
                  child: Text(l10n.cacheSystemUpgradeAction),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
