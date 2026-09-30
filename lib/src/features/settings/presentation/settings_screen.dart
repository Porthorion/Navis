import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final adaptiveLayoutClass = adaptiveContext.adaptiveLayoutClass;
    final compactWideLandscapeMode = adaptiveContext.useCompactWideLandscape;
    final compactHorizontalInset = compactWideLandscapeMode ? 10.0 : 12.0;
    final tabletMode =
        !adaptiveContext.useDesktopShell &&
        adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;
    final groupConnection = l10n.settingsGroupConnection;
    final groupStorage = l10n.settingsGroupStorage;
    final groupDeviceStorageCache = l10n.settingsGroupDeviceStorageCache;
    final groupPlayback = l10n.settingsGroupPlayback;
    final groupLibrarySynchronization =
        l10n.settingsGroupLibrarySynchronization;
    final groupOther = l10n.settingsGroupOther;
    final groupDesktop = l10n.settingsGroupDesktop;
    final List<_SettingsEntry> coreEntries = <_SettingsEntry>[
      _SettingsEntry(
        icon: Icons.storage_outlined,
        title: l10n.settingsServerTitle,
        subtitle: l10n.settingsServerSubtitle,
        page: SettingsPage.server,
        group: groupConnection,
      ),
      _SettingsEntry(
        icon: Icons.folder_copy_outlined,
        title: l10n.settingsCacheTitle,
        subtitle: l10n.settingsCacheSubtitle,
        page: SettingsPage.cache,
        group: groupDeviceStorageCache,
      ),
      _SettingsEntry(
        icon: Icons.download_outlined,
        title: l10n.downloadsTitle,
        subtitle: l10n.settingsDownloadsSubtitle,
        page: SettingsPage.downloads,
        group: groupStorage,
      ),
      _SettingsEntry(
        icon: Icons.sync_outlined,
        title: l10n.settingsSyncTitle,
        subtitle: l10n.settingsSyncSubtitle,
        page: SettingsPage.sync,
        group: groupLibrarySynchronization,
      ),
      _SettingsEntry(
        icon: Icons.graphic_eq_outlined,
        title: l10n.settingsPlaybackTitle,
        subtitle: l10n.settingsPlaybackSubtitle,
        page: SettingsPage.playback,
        group: groupPlayback,
      ),
      _SettingsEntry(
        icon: Icons.equalizer,
        title: l10n.eqTitle,
        subtitle: ref.watch(eqCapabilitiesProvider).supported
            ? l10n.eqSubtitle
            : l10n.eqUnavailable,
        page: SettingsPage.equalizer,
        group: groupPlayback,
        enabled: ref.watch(eqCapabilitiesProvider).supported,
      ),
      _SettingsEntry(
        icon: Icons.palette_outlined,
        title: l10n.settingsAppearanceTitle,
        subtitle: l10n.settingsAppearanceSubtitle,
        page: SettingsPage.appearance,
        group: groupOther,
      ),
    ];
    final List<_SettingsEntry> desktopEntries = [
      if (adaptiveContext.desktopRuntime)
        _SettingsEntry(
          icon: Icons.picture_in_picture_alt_outlined,
          title: l10n.desktopWindowTitle,
          subtitle: l10n.desktopWindowSubtitle,
          page: SettingsPage.desktopWindow,
          group: groupDesktop,
        ),
      if (adaptiveContext.desktopRuntime)
        _SettingsEntry(
          icon: Icons.keyboard_command_key_rounded,
          title: l10n.settingsDesktopShortcutsTitle,
          subtitle: l10n.settingsDesktopShortcutsSubtitle,
          page: SettingsPage.shortcuts,
          group: groupDesktop,
        ),
    ];
    final _SettingsEntry aboutEntry = _SettingsEntry(
      icon: Icons.info_outline,
      title: l10n.aboutTitle,
      subtitle: null,
      page: SettingsPage.about,
      group: groupOther,
    );
    final _SettingsEntry quickCustomizationEntry = _SettingsEntry(
      icon: Icons.auto_awesome_outlined,
      title: l10n.settingsRunQuickCustomizationTitle,
      subtitle: l10n.settingsRunQuickCustomizationSubtitle,
      group: groupOther,
    );
    // Desktop entries come between core and About so About is always last.
    final entries = <_SettingsEntry>[
      ...coreEntries,
      ...desktopEntries,
      quickCustomizationEntry,
      aboutEntry,
    ];

    final groups = <String, List<_SettingsEntry>>{};
    for (final entry in entries) {
      groups.putIfAbsent(entry.group, () => <_SettingsEntry>[]).add(entry);
    }

    if (!adaptiveContext.useDesktopShell && !tabletMode) {
      final portraitPhone =
          MediaQuery.orientationOf(context) == Orientation.portrait;
      return Scaffold(
        appBar: portraitPhone ? null : AppBar(title: Text(l10n.settingsTitle)),
        body: SafeArea(
          top: portraitPhone,
          child: ListView(
            padding: const EdgeInsets.only(top: 12),
            children: <Widget>[
              for (final group in groups.entries) ...<Widget>[
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 4),
                  child: Semantics(
                    header: true,
                    child: Text(
                      group.key,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                for (final entry in group.value)
                  ListTile(
                    leading: Icon(entry.icon),
                    title: Text(entry.title),
                    subtitle: entry.subtitle == null
                        ? null
                        : Text(entry.subtitle!),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: entry.enabled
                        ? () => _open(context, ref, entry)
                        : null,
                  ),
              ],
            ],
          ),
        ),
      );
    }

    if (tabletMode) {
      final maxWidth = adaptiveLayoutClass == AdaptiveLayoutClass.tabletExpanded
          ? (compactWideLandscapeMode ? double.infinity : 980.0)
          : 860.0;
      final tabletList = ListView(
        padding: EdgeInsets.fromLTRB(
          compactHorizontalInset,
          12,
          compactHorizontalInset,
          20,
        ),
        children: <Widget>[
          for (final group in groups.entries) ...<Widget>[
            if (compactWideLandscapeMode) ...<Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                child: Text(
                  group.key,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final entry in group.value)
                ListTile(
                  leading: Icon(entry.icon),
                  title: Text(entry.title),
                  subtitle: entry.subtitle == null
                      ? null
                      : Text(entry.subtitle!),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: entry.enabled
                      ? () => _open(context, ref, entry)
                      : null,
                ),
              const SizedBox(height: 8),
            ] else ...<Widget>[
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                      child: Text(
                        group.key,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    for (final entry in group.value)
                      ListTile(
                        leading: Icon(entry.icon),
                        title: Text(entry.title),
                        subtitle: entry.subtitle == null
                            ? null
                            : Text(entry.subtitle!),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: entry.enabled
                            ? () => _open(context, ref, entry)
                            : null,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ],
      );
      return Scaffold(
        appBar: AppBar(title: Text(l10n.settingsTitle)),
        body: SafeArea(
          top: false,
          left: !compactWideLandscapeMode,
          right: !compactWideLandscapeMode,
          child: compactWideLandscapeMode
              ? tabletList
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: tabletList,
                  ),
                ),
        ),
      );
    }

    final desktopIconsOnly = DesktopNavigationPresentationScope.iconsOnlyOf(
      context,
    );
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            24,
            desktopIconsOnly ? 20 : 16,
            24,
            24,
          ),
          children: <Widget>[
            if (desktopIconsOnly) ...<Widget>[
              DesktopSectionHeader(
                title: l10n.settingsTitle,
                subtitle: l10n.settingsDesktopWorkspaceSubtitle,
              ),
              const SizedBox(height: 4),
            ],
            for (final group in groups.entries) ...<Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                child: Text(
                  group.key,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final entry in group.value)
                DesktopListRow(
                  leading: Icon(entry.icon),
                  title: entry.title,
                  subtitle: entry.subtitle,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: entry.enabled
                      ? () => _open(context, ref, entry)
                      : null,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

void _open(BuildContext context, WidgetRef ref, _SettingsEntry entry) {
  final page = entry.page;
  if (page == null) {
    NavService.openOnboardingReview(context, ref);
  } else {
    NavService.openSettingsPage(context, ref, page);
  }
}

class _SettingsEntry {
  const _SettingsEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.group,
    this.page,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// The Settings page this entry opens; null opens the onboarding review.
  final SettingsPage? page;
  final String group;
  final bool enabled;
}
