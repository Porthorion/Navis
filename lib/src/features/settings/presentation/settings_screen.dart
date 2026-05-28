import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/routing/desktop_layout.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final listenTogetherStatus = ref.watch(
      groupListeningVoyageConnectionStatusProvider,
    );
    final adaptiveLayoutClass = adaptiveContext.adaptiveLayoutClass;
    final compactWideLandscapeMode = adaptiveContext.useCompactWideLandscape;
    final compactHorizontalInset = compactWideLandscapeMode ? 10.0 : 12.0;
    final tabletMode =
        !adaptiveContext.useDesktopShell &&
        adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;
    const groupConnection = 'Connection';
    const groupStorage = 'Storage';
    const groupPlayback = 'Playback';
    const groupAutomation = 'Automation';
    const groupExternalServices = 'External Services';
    const groupAbout = 'About';
    const groupDesktop = 'Desktop';
    const groupListenTogether = 'Listen Together';
    final List<_SettingsEntry> coreEntries = <_SettingsEntry>[
      _SettingsEntry(
        icon: Icons.storage_outlined,
        title: l10n.settingsServerTitle,
        subtitle: l10n.settingsServerSubtitle,
        route: '/settings/server',
        group: groupConnection,
      ),
      _SettingsEntry(
        icon: Icons.folder_copy_outlined,
        title: l10n.settingsCacheTitle,
        subtitle: l10n.settingsCacheSubtitle,
        route: '/settings/cache',
        group: groupStorage,
      ),
      _SettingsEntry(
        icon: Icons.download_outlined,
        title: l10n.downloadsTitle,
        subtitle: l10n.settingsDownloadsSubtitle,
        route: '/settings/downloads',
        group: groupStorage,
      ),
      _SettingsEntry(
        icon: Icons.sync_outlined,
        title: l10n.settingsSyncTitle,
        subtitle: l10n.settingsSyncSubtitle,
        route: '/settings/sync',
        group: groupAutomation,
      ),
      if (listenTogetherStatus.isHealthy)
        const _SettingsEntry(
          icon: Icons.people_alt_outlined,
          title: 'Listen Together',
          subtitle: 'Create groups, join rooms, and manage shared playback',
          route: '/settings/group-listening',
          group: groupListenTogether,
        ),
      _SettingsEntry(
        icon: Icons.graphic_eq_outlined,
        title: l10n.settingsPlaybackTitle,
        subtitle: l10n.settingsPlaybackSubtitle,
        route: '/settings/playback',
        group: groupPlayback,
      ),
      const _SettingsEntry(
        icon: Icons.hub_outlined,
        title: 'External Services',
        subtitle: 'Connect Last.fm and ListenBrainz scrobbling',
        route: '/settings/external-services',
        group: groupExternalServices,
      ),
      _SettingsEntry(
        icon: Icons.palette_outlined,
        title: l10n.settingsAppearanceTitle,
        subtitle: l10n.settingsAppearanceSubtitle,
        route: '/settings/appearance',
        group: groupPlayback,
      ),
    ];
    final List<_SettingsEntry> desktopEntries = [
      if (adaptiveContext.desktopRuntime)
        const _SettingsEntry(
          icon: Icons.picture_in_picture_alt_outlined,
          title: 'Desktop Window',
          subtitle: 'Configure Focus Player Mode and compact desktop behavior',
          route: '/settings/desktop-window',
          group: groupDesktop,
        ),
      if (adaptiveContext.desktopRuntime)
        const _SettingsEntry(
          icon: Icons.keyboard_command_key_rounded,
          title: 'Keyboard Shortcuts',
          subtitle: 'Customize desktop key bindings',
          route: '/settings/shortcuts',
          group: groupDesktop,
        ),
    ];
    final _SettingsEntry aboutEntry = _SettingsEntry(
      icon: Icons.info_outline,
      title: l10n.aboutTitle,
      subtitle: null,
      route: '/settings/about',
      group: groupAbout,
    );
    // Desktop entries come between core and About so About is always last.
    final entries = <_SettingsEntry>[
      ...coreEntries,
      ...desktopEntries,
      aboutEntry,
    ];

    final groups = <String, List<_SettingsEntry>>{};
    for (final entry in entries) {
      groups.putIfAbsent(entry.group, () => <_SettingsEntry>[]).add(entry);
    }

    if (!adaptiveContext.useDesktopShell && !tabletMode) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.settingsTitle)),
        body: ListView(
          children: <Widget>[
            for (final entry in entries)
              ListTile(
                leading: Icon(entry.icon),
                title: Text(entry.title),
                subtitle: entry.subtitle == null ? null : Text(entry.subtitle!),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(entry.route),
              ),
          ],
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
                  onTap: () => context.push(entry.route),
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
                        onTap: () => context.push(entry.route),
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

    return Scaffold(
      body: SafeArea(
        child: DesktopFrame(
          layoutClass: adaptiveContext.desktopLayoutClass,
          child: ListView(
            children: <Widget>[
              DesktopSectionHeader(
                title: l10n.settingsTitle,
                subtitle: 'Desktop workspace controls and app preferences',
              ),
              const SizedBox(height: 6),
              for (final group in groups.entries) ...<Widget>[
                DesktopPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        group.key,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      for (final entry in group.value)
                        DesktopListRow(
                          leading: Icon(entry.icon),
                          title: entry.title,
                          subtitle: entry.subtitle,
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => context.push(entry.route),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsEntry {
  const _SettingsEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
    required this.group,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String route;
  final String group;
}
