import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/l10n/app_localizations.dart';

class DesktopWindowSettingsScreen extends ConsumerWidget {
  const DesktopWindowSettingsScreen({super.key});

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

    final content = ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: <Widget>[
        DesktopSectionHeader(
          title: l10n.desktopWindowTitle,
          subtitle: l10n.desktopWindowSubtitle,
        ),
        DesktopPanel(
          child: Column(
            children: <Widget>[
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
                    ? (value) => unawaited(
                        windowController.setMiniAlwaysOnTop(value),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ],
    );

    if (adaptiveContext.useDesktopShell) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.desktopWindowTitle)),
        body: DesktopFrame(
          layoutClass: adaptiveContext.desktopLayoutClass,
          child: content,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.desktopWindowTitle)),
      body: content,
    );
  }
}
