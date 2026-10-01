import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/app_routes.dart';

class DesktopWindowSettingsScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final l10n = AppLocalizations.of(context)!;
    final desktopRuntime = adaptiveContext.desktopRuntime;
    final windowController = ref.watch(desktopWindowControllerProvider);

    if (!desktopRuntime) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.desktopWindowTitle)),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              l10n.desktopWindowUnavailable,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              NavService.back(context, fallback: AppRoutes.settings),
        ),
        title: Text(l10n.desktopWindowTitle),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            children: <Widget>[
              Text(
                l10n.desktopWindowSubtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.picture_in_picture_alt_outlined),
                title: Text(l10n.desktopMiniPlayerTitle),
                subtitle: Text(l10n.desktopMiniPlayerDescription),
                trailing: FilledButton.tonal(
                  onPressed:
                      windowController.isApplyingMode ||
                          (windowController.isMiniPlayerMode &&
                              !windowController.desktopViewAvailable)
                      ? null
                      : () => unawaited(
                          windowController.setMiniPlayerMode(
                            !windowController.isMiniPlayerMode,
                          ),
                        ),
                  child: Text(
                    windowController.isMiniPlayerMode
                        ? l10n.desktopReturnToView
                        : l10n.desktopMiniPlayerOpen,
                  ),
                ),
              ),
              const Divider(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.push_pin_outlined),
                title: Text(l10n.desktopMiniPlayerKeepOnTop),
                subtitle: Text(
                  windowController.supportsMiniAlwaysOnTop
                      ? l10n.desktopMiniPlayerKeepOnTopDescription
                      : l10n.desktopMiniPlayerKeepOnTopUnavailable,
                ),
                value: windowController.miniAlwaysOnTop,
                onChanged: windowController.supportsMiniAlwaysOnTop
                    ? (value) =>
                          unawaited(windowController.setMiniAlwaysOnTop(value))
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
