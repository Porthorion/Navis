import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final desktopUiV1 = ref.watch(desktopUiV1EnabledProvider);
    final adaptiveLayoutClass = resolveAdaptiveLayoutClass(
      MediaQuery.sizeOf(context).width,
    );
    final tabletMode =
        !isDesktopRuntime &&
        adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;
    const groupConnection = 'Connection';
    const groupStorage = 'Storage';
    const groupPlayback = 'Playback';
    const groupAutomation = 'Automation';
    const groupAbout = 'About';
    final entries = <_SettingsEntry>[
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
      _SettingsEntry(
        icon: Icons.graphic_eq_outlined,
        title: l10n.settingsPlaybackTitle,
        subtitle: l10n.settingsPlaybackSubtitle,
        route: '/settings/playback',
        group: groupPlayback,
      ),
      _SettingsEntry(
        icon: Icons.palette_outlined,
        title: l10n.settingsAppearanceTitle,
        subtitle: l10n.settingsAppearanceSubtitle,
        route: '/settings/appearance',
        group: groupPlayback,
      ),
      _SettingsEntry(
        icon: Icons.info_outline,
        title: l10n.aboutTitle,
        subtitle: null,
        route: '/settings/about',
        group: groupAbout,
      ),
    ];

    final groups = <String, List<_SettingsEntry>>{};
    for (final entry in entries) {
      groups.putIfAbsent(entry.group, () => <_SettingsEntry>[]).add(entry);
    }

    if (!desktopUiV1 && !tabletMode) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.settingsTitle)),
        body: ListView(
          children: <Widget>[
            if (isDesktopRuntime)
              _DesktopUiV1SwitchTile(
                desktopUiV1: desktopUiV1,
                onChanged: (value) => unawaited(
                  ref
                      .read(navisDatabaseProvider)
                      .appSettingsDao
                      .updateDesktopUiV1Enabled(enabled: value),
                ),
                showSurface: false,
              ),
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

    if (!desktopUiV1 && tabletMode) {
      final maxWidth = adaptiveLayoutClass == AdaptiveLayoutClass.tabletExpanded
          ? 980.0
          : 860.0;
      return Scaffold(
        appBar: AppBar(title: Text(l10n.settingsTitle)),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                children: <Widget>[
                  for (final group in groups.entries) ...<Widget>[
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                            child: Text(
                              group.key,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
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
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: DesktopFrame(
          layoutClass: resolveDesktopLayoutClass(
            MediaQuery.sizeOf(context).width,
          ),
          child: ListView(
            children: <Widget>[
              DesktopSectionHeader(
                title: l10n.settingsTitle,
                subtitle: 'Desktop workspace controls and app preferences',
              ),
              const SizedBox(height: 6),
              if (isDesktopRuntime) ...<Widget>[
                _DesktopUiV1SwitchTile(
                  desktopUiV1: desktopUiV1,
                  onChanged: (value) => unawaited(
                    ref
                        .read(navisDatabaseProvider)
                        .appSettingsDao
                        .updateDesktopUiV1Enabled(enabled: value),
                  ),
                  showSurface: true,
                ),
                const SizedBox(height: 12),
              ],
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

class _DesktopUiV1SwitchTile extends StatelessWidget {
  const _DesktopUiV1SwitchTile({
    required this.desktopUiV1,
    required this.onChanged,
    required this.showSurface,
  });

  final bool desktopUiV1;
  final ValueChanged<bool> onChanged;
  final bool showSurface;

  @override
  Widget build(BuildContext context) {
    final tile = SwitchListTile.adaptive(
      value: desktopUiV1,
      title: const Text('Desktop UI V1'),
      subtitle: const Text(
        'Enable the desktop-first workspace layout for core screens.',
      ),
      onChanged: onChanged,
    );

    if (!showSurface) {
      return tile;
    }

    return DesktopPanel(child: tile);
  }
}
