import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/common_widgets/navis_switch.dart';
import 'package:navis/src/features/settings/presentation/desktop_navbar_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

const _headerPadding = EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8);

/// Desktop-only settings: Mini Player window, sidebar navigation and a link to
/// the keyboard shortcuts page.
class DesktopSettingsScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final l10n = AppLocalizations.of(context)!;
    final desktopRuntime = adaptiveContext.desktopRuntime;
    final windowController = ref.watch(desktopWindowControllerProvider);

    if (!desktopRuntime) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.desktopSettingsTitle)),
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
        title: Text(l10n.desktopSettingsTitle),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 24, 8, 32),
            children: <Widget>[
              NavisSectionHeader(
                title: l10n.desktopSettingsWindowSection,
                compact: true,
                maxLines: null,
                padding: _headerPadding,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  l10n.desktopWindowSubtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.picture_in_picture_alt_outlined),
                title: Text(l10n.desktopMiniPlayerTitle),
                subtitle: Text(l10n.desktopMiniPlayerDescription),
                trailing: FilledButton.tonal(
                  style: NavisColorStyleData.tonalStyleOf(context),
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
              NavisSwitchListTile(
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
              const SizedBox(height: 24),
              NavisSectionHeader(
                title: l10n.desktopNavbarSectionLabel,
                compact: true,
                maxLines: null,
                padding: _headerPadding,
              ),
              DesktopNavbarSettings(
                currentStyle: ref.watch(desktopNavbarStyleProvider),
                autohideEnabled: ref.watch(desktopNavbarAutohideProvider),
                onStyleChanged: (style) async {
                  final db = ref.read(navisDatabaseProvider);
                  await db.appSettingsDao.updateDesktopNavbarStyle(style);
                },
                onAutohideChanged: (enabled) async {
                  final db = ref.read(navisDatabaseProvider);
                  await db.appSettingsDao.updateDesktopNavbarAutohide(enabled);
                },
              ),
              const SizedBox(height: 24),
              NavisSectionHeader(
                title: l10n.settingsDesktopShortcutsTitle,
                compact: true,
                maxLines: null,
                padding: _headerPadding,
              ),
              ListTile(
                leading: const Icon(Icons.keyboard_command_key_rounded),
                title: Text(l10n.settingsDesktopShortcutsTitle),
                subtitle: Text(l10n.settingsDesktopShortcutsSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => NavService.openSettingsPage(
                  context,
                  ref,
                  SettingsPage.shortcuts,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
